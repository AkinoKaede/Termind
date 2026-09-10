import Foundation
import SwiftData

@Model
final class PersistentAIConfigurationSyncEntry {
    @Attribute(.unique) var recordName = ""
    var kind = SettingsRecordKind.provider.rawValue
    var entityID = ""
    var envelopeData = Data()
    var systemFieldsData: Data?
    var needsUpload = false

    init(envelope: SettingsEnvelope, needsUpload: Bool) throws {
        try apply(envelope, needsUpload: needsUpload)
    }

    func apply(_ envelope: SettingsEnvelope, needsUpload: Bool) throws {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id
        envelopeData = try SettingsSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    var envelope: SettingsEnvelope? { try? SettingsSyncCodec.decode(envelopeData) }
}

@Model
final class PersistentAIConfigurationSyncState {
    @Attribute(.unique) var key = "ai-configuration-sync"
    var installationID = UUID()
    var engineStateData: Data?
    var boundUserRecordName: String?
    var pendingUserRecordName: String?
    var bootstrapCompleted = false
    var lastSuccessfulSync: Date?

    init() {}
}

@Model
final class PersistentAIConfigurationSyncQuarantine {
    @Attribute(.unique) var recordName = ""
    var payloadData = Data()
    var reason = ""
    var receivedAt = Date()

    init(recordName: String, payloadData: Data, reason: String) {
        self.recordName = recordName
        self.payloadData = payloadData
        self.reason = reason
    }
}

nonisolated enum SettingsSyncPersistenceError: LocalizedError {
    case invalidEnvelope(String)
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let recordName):
            String(localized: "The iCloud settings record \(recordName) is invalid.")
        case .unsupportedFormat(let version):
            String(localized: "This settings record requires sync format \(version).")
        }
    }
}

nonisolated enum SettingsSyncCodec {
    static func encode(_ envelope: SettingsEnvelope) throws -> Data {
        guard envelope.isValid else {
            throw SettingsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) throws -> SettingsEnvelope {
        try JSONDecoder().decode(SettingsEnvelope.self, from: data)
    }
}

nonisolated struct SettingsRemoteMerge: Sendable {
    var accepted: [SettingsEnvelope] = []
    var needsUpload: Set<SettingsRecordKey> = []
}

nonisolated struct SettingsOutgoingEntry: Sendable {
    var envelope: SettingsEnvelope
    var systemFieldsData: Data?
}

@MainActor
final class SettingsSyncJournal {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func state() throws -> PersistentAIConfigurationSyncState {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncState>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let state = PersistentAIConfigurationSyncState()
        context.insert(state)
        return state
    }

    @discardableResult
    func bootstrapIfNeeded(_ snapshot: SettingsSyncSnapshot) throws -> SettingsMutationSet {
        let state = try state()
        guard !state.bootstrapCompleted else { return .empty }
        let existing = try entriesByName()
        var changed = Set<SettingsRecordKey>()
        for payload in snapshot.recordPayloads.values {
            let key = payload.key
            guard existing[key.recordName] == nil else { continue }
            let envelope = SettingsEnvelope(
                key: key, version: .baseline(writerID: state.installationID), payload: payload
            )
            context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: true))
            changed.insert(key)
        }
        state.bootstrapCompleted = true
        return SettingsMutationSet(keys: changed)
    }

    func recordLocalChanges(
        from oldSnapshot: SettingsSyncSnapshot, to newSnapshot: SettingsSyncSnapshot,
        now: Date = .now
    ) throws -> SettingsMutationSet {
        let state = try state()
        let old = oldSnapshot.recordPayloads
        let new = newSnapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<SettingsRecordKey>()

        for (key, payload) in new where old[key] != payload {
            let row = entries[key.recordName]
            let envelope = SettingsEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }

        for key in old.keys where new[key] == nil {
            let row = entries[key.recordName]
            let envelope = SettingsEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }
        return SettingsMutationSet(keys: changed)
    }

    func pendingEnvelopes() throws -> [SettingsEnvelope] {
        try context.fetch(
            FetchDescriptor<PersistentAIConfigurationSyncEntry>(
                predicate: #Predicate { $0.needsUpload }
            )
        ).compactMap(\.envelope)
    }

    func outgoingEntry(for key: SettingsRecordKey) throws -> SettingsOutgoingEntry? {
        guard let row = try entry(recordName: key.recordName), let envelope = row.envelope else {
            return nil
        }
        return SettingsOutgoingEntry(envelope: envelope, systemFieldsData: row.systemFieldsData)
    }

    func envelope(for key: SettingsRecordKey) throws -> SettingsEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }

    func mergeDecision(for remote: [SettingsEnvelope]) throws -> SettingsRemoteMerge {
        var result = SettingsRemoteMerge()
        let entries = try entriesByName()
        // A fetch batch can contain several versions of one record. Compare the
        // newest candidate once, independently of delivery order.
        var candidates: [SettingsRecordKey: SettingsEnvelope] = [:]
        for envelope in remote {
            guard envelope.isValid else {
                throw SettingsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            if let previous = candidates[envelope.key] {
                if envelope.version < previous.version { continue }
                let previousData = try SettingsSyncCodec.encode(previous)
                let incomingData = try SettingsSyncCodec.encode(envelope)
                if envelope.version == previous.version, !previousData.lexicographicallyPrecedes(incomingData) {
                    continue
                }
            }
            candidates[envelope.key] = envelope
        }
        for envelope in candidates.values {
            guard envelope.formatVersion <= SettingsEnvelope.currentFormatVersion else {
                throw SettingsSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
            }
            guard envelope.isValid else {
                throw SettingsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            guard let local = entries[envelope.key.recordName]?.envelope else {
                result.accepted.append(envelope)
                continue
            }
            if local.version.modifiedAt == VaultVersion.baselineDate
                && !local.isDeleted && local != envelope
            {
                result.accepted.append(envelope)
            } else if local.version < envelope.version {
                result.accepted.append(envelope)
            } else if envelope.version < local.version {
                result.needsUpload.insert(local.key)
            } else if local != envelope {
                let localData = try SettingsSyncCodec.encode(local)
                let remoteData = try SettingsSyncCodec.encode(envelope)
                if localData.lexicographicallyPrecedes(remoteData) {
                    result.accepted.append(envelope)
                } else {
                    result.needsUpload.insert(local.key)
                }
            }
        }
        return result
    }

    func acceptRemote(_ envelopes: [SettingsEnvelope]) throws {
        var entries = try entriesByName()
        for envelope in envelopes {
            try store(envelope, needsUpload: false, in: &entries)
        }
    }

    func markNeedsUpload(_ keys: Set<SettingsRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys { entries[key.recordName]?.needsUpload = true }
    }

    func markUploaded(_ key: SettingsRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version else {
            return
        }
        row.needsUpload = false
    }

    func updateSystemFields(_ data: Data?, for key: SettingsRecordKey) throws {
        try entry(recordName: key.recordName)?.systemFieldsData = data
    }

    func quarantine(recordName: String, payloadData: Data, reason: String) throws {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncQuarantine>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first {
            row.payloadData = payloadData
            row.reason = reason
            row.receivedAt = .now
        } else {
            context.insert(
                PersistentAIConfigurationSyncQuarantine(
                    recordName: recordName, payloadData: payloadData, reason: reason
                ))
        }
    }

    func clearQuarantine(recordName: String) throws {
        try context.delete(
            model: PersistentAIConfigurationSyncQuarantine.self,
            where: #Predicate { $0.recordName == recordName }
        )
    }

    func firstQuarantineReason() throws -> String? {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncQuarantine>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.reason
    }

    func recordCurrentSnapshot(_ snapshot: SettingsSyncSnapshot, now: Date = .now) throws
        -> SettingsMutationSet
    {
        let state = try state()
        let current = snapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<SettingsRecordKey>()

        for (key, payload) in current {
            let row = entries[key.recordName]
            guard row?.envelope?.payload != payload || row?.envelope?.isDeleted != false else {
                continue
            }
            let envelope = SettingsEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }

        for row in entries.values {
            guard let envelope = row.envelope, !envelope.isDeleted,
                current[envelope.key] == nil
            else { continue }
            let tombstone = SettingsEnvelope(
                key: envelope.key,
                version: .next(after: envelope.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            try row.apply(tombstone, needsUpload: true)
            changed.insert(envelope.key)
        }
        return SettingsMutationSet(keys: changed)
    }

    func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            guard let envelope = row.envelope else { continue }
            if envelope.isDeleted {
                context.delete(row)
            } else {
                row.needsUpload = true
                row.systemFieldsData = nil
            }
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    func markAllEntriesNeedsUploadAfterZoneReset() throws {
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            row.needsUpload = true
            row.systemFieldsData = nil
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    func markAllEntriesNeedsUploadAfterEnvironmentChange() throws {
        try markAllEntriesNeedsUploadAfterZoneReset()
    }

    private func entry(recordName: String) throws -> PersistentAIConfigurationSyncEntry? {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncEntry>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func store(
        _ envelope: SettingsEnvelope, needsUpload: Bool,
        in entries: inout [String: PersistentAIConfigurationSyncEntry]
    ) throws {
        if let row = entries[envelope.key.recordName] {
            try row.apply(envelope, needsUpload: needsUpload)
        } else {
            let row = try PersistentAIConfigurationSyncEntry(
                envelope: envelope, needsUpload: needsUpload
            )
            context.insert(row)
            entries[envelope.key.recordName] = row
        }
    }

    private func entriesByName() throws -> [String: PersistentAIConfigurationSyncEntry] {
        Dictionary(
            try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).map {
                ($0.recordName, $0)
            },
            uniquingKeysWith: { first, duplicate in
                if let firstVersion = first.envelope?.version,
                    let duplicateVersion = duplicate.envelope?.version,
                    firstVersion < duplicateVersion
                {
                    return duplicate
                }
                return first
            }
        )
    }
}

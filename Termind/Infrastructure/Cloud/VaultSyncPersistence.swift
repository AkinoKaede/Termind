import Foundation
import SwiftData

@Model
final class PersistentVaultSyncEntry {
    @Attribute(.unique) var recordName = ""
    var kind = VaultRecordKind.host.rawValue
    var entityID = UUID()
    var envelopeData = Data()
    var systemFieldsData: Data?
    var needsUpload = false

    init(envelope: VaultEnvelope, needsUpload: Bool) throws {
        apply(envelope, needsUpload: needsUpload)
    }

    func apply(_ envelope: VaultEnvelope, needsUpload: Bool) {
        recordName = envelope.key.recordName
        kind = envelope.key.kind.rawValue
        entityID = envelope.key.id
        envelopeData = VaultSyncCodec.encode(envelope)
        self.needsUpload = needsUpload
    }

    var envelope: VaultEnvelope? { try? VaultSyncCodec.decode(envelopeData) }
}

@Model
final class PersistentVaultSyncState {
    @Attribute(.unique) var key = "vault-sync"
    var installationID = UUID()
    var engineStateData: Data?
    var boundUserRecordName: String?
    var pendingUserRecordName: String?
    var bootstrapCompleted = false
    var lastSuccessfulSync: Date?

    init() {}
}

@Model
final class PersistentVaultSyncQuarantine {
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

nonisolated enum VaultSyncPersistenceError: LocalizedError {
    case invalidEnvelope(String)
    case unsupportedFormat(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let recordName):
            String(localized: "The iCloud Vault record \(recordName) is invalid.")
        case .unsupportedFormat(let version):
            String(localized: "This Vault record requires sync format \(version).")
        }
    }
}

nonisolated enum VaultSyncCodec {
    static func encode(_ envelope: VaultEnvelope) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(envelope)) ?? Data()
    }

    static func decode(_ data: Data) throws -> VaultEnvelope {
        try JSONDecoder().decode(VaultEnvelope.self, from: data)
    }
}

nonisolated struct VaultRemoteMerge: Sendable {
    var accepted: [VaultEnvelope] = []
    var needsUpload: Set<VaultRecordKey> = []
}

nonisolated struct VaultOutgoingEntry: Sendable {
    var envelope: VaultEnvelope
    var systemFieldsData: Data?
}

extension VaultSnapshot {
    nonisolated var recordPayloads: [VaultRecordKey: VaultRecordPayload] {
        var result: [VaultRecordKey: VaultRecordPayload] = [:]
        for value in hosts { result[VaultRecordKey(kind: .host, id: value.id)] = .host(value) }
        for value in groups {
            result[VaultRecordKey(kind: .hostGroup, id: value.id)] = .hostGroup(value)
        }
        for value in identities {
            result[VaultRecordKey(kind: .identity, id: value.id)] = .identity(value)
        }
        for value in keys {
            result[VaultRecordKey(kind: .sshKey, id: value.id)] = .sshKey(value)
        }
        for value in knownHosts {
            result[VaultRecordKey(kind: .knownHost, id: value.id)] = .knownHost(value)
        }
        for value in snippets {
            result[VaultRecordKey(kind: .snippet, id: value.id)] = .snippet(value)
        }
        for value in snippetPackages {
            result[VaultRecordKey(kind: .snippetPackage, id: value.id)] = .snippetPackage(value)
        }
        for value in portForwardings {
            result[VaultRecordKey(kind: .portForwarding, id: value.id)] = .portForwarding(value)
        }
        return result
    }

    nonisolated mutating func apply(_ envelope: VaultEnvelope) throws {
        guard envelope.formatVersion <= VaultEnvelope.currentFormatVersion else {
            throw VaultSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
        }
        guard envelope.isValid else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }

        if envelope.isDeleted {
            remove(envelope.key)
            return
        }
        guard let payload = envelope.payload else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        switch payload {
        case .host(let value): upsert(value, in: &hosts)
        case .hostGroup(let value): upsert(value, in: &groups)
        case .identity(let value): upsert(value, in: &identities)
        case .sshKey(let value): upsert(value, in: &keys)
        case .knownHost(let value): upsert(value, in: &knownHosts)
        case .snippet(let value): upsert(value, in: &snippets)
        case .snippetPackage(let value): upsert(value, in: &snippetPackages)
        case .portForwarding(let value): upsert(value, in: &portForwardings)
        }
    }

    private nonisolated mutating func remove(_ key: VaultRecordKey) {
        switch key.kind {
        case .host: hosts.removeAll { $0.id == key.id }
        case .hostGroup: groups.removeAll { $0.id == key.id }
        case .identity: identities.removeAll { $0.id == key.id }
        case .sshKey: keys.removeAll { $0.id == key.id }
        case .knownHost: knownHosts.removeAll { $0.id == key.id }
        case .snippet: snippets.removeAll { $0.id == key.id }
        case .snippetPackage: snippetPackages.removeAll { $0.id == key.id }
        case .portForwarding: portForwardings.removeAll { $0.id == key.id }
        }
    }

    private nonisolated func upsert<Value: Identifiable>(
        _ value: Value, in values: inout [Value]
    ) where Value.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else { values.append(value) }
    }
}

@MainActor
final class VaultSyncJournal {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func state() throws -> PersistentVaultSyncState {
        var descriptor = FetchDescriptor<PersistentVaultSyncState>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let state = PersistentVaultSyncState()
        context.insert(state)
        return state
    }

    @discardableResult
    func bootstrapIfNeeded(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        let state = try state()
        guard !state.bootstrapCompleted else { return .empty }
        let existing = try entriesByName()
        var changed = Set<VaultRecordKey>()
        for payload in snapshot.recordPayloads.values {
            let key = payload.key
            guard existing[key.recordName] == nil else { continue }
            let envelope = VaultEnvelope(
                key: key, version: .baseline(writerID: state.installationID), payload: payload
            )
            context.insert(try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true))
            changed.insert(key)
        }
        state.bootstrapCompleted = true
        return VaultMutationSet(keys: changed)
    }

    func recordLocalChanges(
        from oldSnapshot: VaultSnapshot, to newSnapshot: VaultSnapshot,
        now: Date = .now
    ) throws -> VaultMutationSet {
        let state = try state()
        let old = oldSnapshot.recordPayloads
        let new = newSnapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<VaultRecordKey>()

        for (key, payload) in new where old[key] != payload {
            let row = entries[key.recordName]
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            if let row { row.apply(envelope, needsUpload: true) }
            else {
                let inserted = try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true)
                context.insert(inserted)
                entries[key.recordName] = inserted
            }
            changed.insert(key)
        }

        for key in old.keys where new[key] == nil {
            let row = entries[key.recordName]
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            if let row { row.apply(envelope, needsUpload: true) }
            else {
                let inserted = try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true)
                context.insert(inserted)
                entries[key.recordName] = inserted
            }
            changed.insert(key)
        }
        return VaultMutationSet(keys: changed)
    }

    func pendingEnvelopes() throws -> [VaultEnvelope] {
        try context.fetch(
            FetchDescriptor<PersistentVaultSyncEntry>(
                predicate: #Predicate { $0.needsUpload }
            )
        ).compactMap(\.envelope)
    }

    func outgoingEntry(for key: VaultRecordKey) throws -> VaultOutgoingEntry? {
        guard let row = try entry(recordName: key.recordName), let envelope = row.envelope else {
            return nil
        }
        return VaultOutgoingEntry(envelope: envelope, systemFieldsData: row.systemFieldsData)
    }

    func envelope(for key: VaultRecordKey) throws -> VaultEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }

    func mergeDecision(for remote: [VaultEnvelope]) throws -> VaultRemoteMerge {
        var result = VaultRemoteMerge()
        let entries = try entriesByName()
        for envelope in remote {
            guard envelope.formatVersion <= VaultEnvelope.currentFormatVersion else {
                throw VaultSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
            }
            guard envelope.isValid else {
                throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            guard let local = entries[envelope.key.recordName]?.envelope else {
                result.accepted.append(envelope)
                continue
            }
            if local.version < envelope.version { result.accepted.append(envelope) }
            else if envelope.version < local.version { result.needsUpload.insert(local.key) }
            else if local != envelope {
                let localData = VaultSyncCodec.encode(local)
                let remoteData = VaultSyncCodec.encode(envelope)
                if localData.lexicographicallyPrecedes(remoteData) {
                    result.accepted.append(envelope)
                } else {
                    result.needsUpload.insert(local.key)
                }
            }
        }
        return result
    }

    func acceptRemote(_ envelopes: [VaultEnvelope]) throws {
        var entries = try entriesByName()
        for envelope in envelopes {
            if let row = entries[envelope.key.recordName] {
                row.apply(envelope, needsUpload: false)
            } else {
                let row = try PersistentVaultSyncEntry(envelope: envelope, needsUpload: false)
                context.insert(row)
                entries[envelope.key.recordName] = row
            }
        }
    }

    func markNeedsUpload(_ keys: Set<VaultRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys { entries[key.recordName]?.needsUpload = true }
    }

    func markUploaded(_ key: VaultRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version else {
            return
        }
        row.needsUpload = false
    }

    func updateSystemFields(_ data: Data?, for key: VaultRecordKey) throws {
        try entry(recordName: key.recordName)?.systemFieldsData = data
    }

    func quarantine(recordName: String, payloadData: Data, reason: String) throws {
        var descriptor = FetchDescriptor<PersistentVaultSyncQuarantine>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first {
            row.payloadData = payloadData
            row.reason = reason
            row.receivedAt = .now
        } else {
            context.insert(PersistentVaultSyncQuarantine(
                recordName: recordName, payloadData: payloadData, reason: reason
            ))
        }
    }

    func clearQuarantine(recordName: String) throws {
        try context.delete(
            model: PersistentVaultSyncQuarantine.self,
            where: #Predicate { $0.recordName == recordName }
        )
    }

    func firstQuarantineReason() throws -> String? {
        var descriptor = FetchDescriptor<PersistentVaultSyncQuarantine>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.reason
    }

    func recordCurrentSnapshot(_ snapshot: VaultSnapshot, now: Date = .now) throws
        -> VaultMutationSet
    {
        let state = try state()
        let current = snapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<VaultRecordKey>()

        for (key, payload) in current {
            let row = entries[key.recordName]
            guard row?.envelope?.payload != payload || row?.envelope?.isDeleted != false else {
                continue
            }
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            if let row { row.apply(envelope, needsUpload: true) }
            else {
                let inserted = try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true)
                context.insert(inserted)
                entries[key.recordName] = inserted
            }
            changed.insert(key)
        }

        for row in entries.values {
            guard let envelope = row.envelope, !envelope.isDeleted,
                current[envelope.key] == nil
            else { continue }
            let tombstone = VaultEnvelope(
                key: envelope.key,
                version: .next(after: envelope.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            row.apply(tombstone, needsUpload: true)
            changed.insert(envelope.key)
        }
        return VaultMutationSet(keys: changed)
    }

    func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) {
            guard let envelope = row.envelope else { continue }
            if envelope.isDeleted { context.delete(row) }
            else {
                row.needsUpload = true
                row.systemFieldsData = nil
            }
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    func markAllEntriesNeedsUploadAfterZoneReset() throws {
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) {
            row.needsUpload = true
            row.systemFieldsData = nil
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    private func entry(recordName: String) throws -> PersistentVaultSyncEntry? {
        var descriptor = FetchDescriptor<PersistentVaultSyncEntry>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func entriesByName() throws -> [String: PersistentVaultSyncEntry] {
        Dictionary(
            try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).map {
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

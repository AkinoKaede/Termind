import Foundation
import SwiftData
import TermindDomain

public nonisolated struct SettingsRemoteMerge: Sendable {
    public var accepted: [SettingsEnvelope] = []
    public var needsUpload: Set<SettingsRecordKey> = []
}

public nonisolated struct SettingsOutgoingEntry: Sendable {
    public var envelope: SettingsEnvelope
    public var systemFieldsData: Data?
    public init(envelope: SettingsEnvelope, systemFieldsData: Data? = nil) {
        self.envelope = envelope
        self.systemFieldsData = systemFieldsData
    }
}

@MainActor
public final class SettingsSyncJournal {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    /// Moves the pre-Guardian role record onto its canonical key. The legacy
    /// row cannot be uploaded by current code because its decoded role is
    /// `.guardian` while its record name is still `securityReview`.
    ///
    /// The replacement deliberately has no CloudKit system fields: those
    /// fields belong to the old record ID and must never be reused for the new
    /// `v1/role/guardian` record.
    public func migrateLegacyGuardianRole() throws -> SettingsMutationSet {
        let legacyKey = SettingsRecordKey(kind: .role, id: SettingsRecordKey.legacySecurityReviewID)
        guard let legacyRow = try entry(recordName: legacyKey.recordName),
            let legacyEnvelope = legacyRow.envelope,
            legacyEnvelope.isValidLegacyGuardianRecord
        else { return .empty }

        let migrated = legacyEnvelope.canonicalized
        let canonicalKey = migrated.key
        let canonicalRow = try entry(recordName: canonicalKey.recordName)
        let winner: SettingsEnvelope
        if let current = canonicalRow?.envelope {
            winner = try preferred(current, migrated)
        } else {
            winner = migrated
        }

        let canonicalChanged = canonicalRow?.envelope != winner
        if canonicalChanged {
            if let canonicalRow {
                try canonicalRow.apply(winner, needsUpload: true)
                canonicalRow.systemFieldsData = nil
            } else {
                context.insert(
                    try PersistentAIConfigurationSyncEntry(envelope: winner, needsUpload: true)
                )
            }
        }
        context.delete(legacyRow)
        try clearQuarantine(recordName: legacyKey.recordName)
        let syncState = try state()
        syncState.engineStateData = nil
        return SettingsMutationSet(keys: canonicalChanged ? [canonicalKey] : [])
    }

    /// Removes records that are retained only for wire compatibility. Resetting
    /// the engine state also drops any pending save for those records without
    /// creating a CloudKit deletion.
    public func discardInactiveEntries() throws {
        let rows = try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).filter {
            $0.envelope?.key.kind.participatesInSync == false
        }
        let quarantines = try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncQuarantine>()).filter {
            SettingsRecordKey(recordName: $0.recordName)?.kind.participatesInSync == false
        }
        for row in quarantines { context.delete(row) }
        if !rows.isEmpty {
            for row in rows { context.delete(row) }
            let syncState = try state()
            syncState.engineStateData = nil
        }
    }

    public func state() throws -> PersistentAIConfigurationSyncState {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncState>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let state = PersistentAIConfigurationSyncState()
        context.insert(state)
        return state
    }

    @discardableResult
    public func bootstrapIfNeeded(_ snapshot: SettingsSyncSnapshot) throws -> SettingsMutationSet {
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

    public func recordLocalChanges(
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

    public func pendingEnvelopes() throws -> [SettingsEnvelope] {
        try context.fetch(
            FetchDescriptor<PersistentAIConfigurationSyncEntry>(
                predicate: #Predicate { $0.needsUpload }
            )
        ).compactMap(\.envelope).filter { $0.key.kind.participatesInSync }
    }

    public func outgoingEntry(for key: SettingsRecordKey) throws -> SettingsOutgoingEntry? {
        guard key.kind.participatesInSync else { return nil }
        guard let row = try entry(recordName: key.recordName), let envelope = row.envelope else {
            return nil
        }
        return SettingsOutgoingEntry(envelope: envelope, systemFieldsData: row.systemFieldsData)
    }

    public func envelope(for key: SettingsRecordKey) throws -> SettingsEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }

    public func mergeDecision(for remote: [SettingsEnvelope]) throws -> SettingsRemoteMerge {
        var result = SettingsRemoteMerge()
        let entries = try entriesByName()
        // A fetch batch can contain several versions of one record. Compare the
        // newest candidate once, independently of delivery order.
        var candidates: [SettingsRecordKey: SettingsEnvelope] = [:]
        for envelope in remote {
            guard envelope.key.kind.participatesInSync else { continue }
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

    public func acceptRemote(_ envelopes: [SettingsEnvelope]) throws {
        var entries = try entriesByName()
        for envelope in envelopes {
            try store(envelope, needsUpload: false, in: &entries)
        }
    }

    public func markNeedsUpload(_ keys: Set<SettingsRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys where key.kind.participatesInSync {
            entries[key.recordName]?.needsUpload = true
        }
    }

    public func markUploaded(_ key: SettingsRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version else {
            return
        }
        row.needsUpload = false
    }

    public func updateSystemFields(_ data: Data?, for key: SettingsRecordKey) throws {
        try entry(recordName: key.recordName)?.systemFieldsData = data
    }

    public func quarantine(recordName: String, payloadData: Data, reason: String) throws {
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

    public func clearQuarantine(recordName: String) throws {
        try context.delete(
            model: PersistentAIConfigurationSyncQuarantine.self,
            where: #Predicate { $0.recordName == recordName }
        )
    }

    public func firstQuarantineReason() throws -> String? {
        var descriptor = FetchDescriptor<PersistentAIConfigurationSyncQuarantine>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.reason
    }

    public func recordCurrentSnapshot(_ snapshot: SettingsSyncSnapshot, now: Date = .now) throws
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
                envelope.key.kind.participatesInSync,
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

    public func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            guard let envelope = row.envelope else { continue }
            guard envelope.key.kind.participatesInSync else {
                row.needsUpload = false
                continue
            }
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

    public func markAllEntriesNeedsUploadAfterZoneReset() throws {
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            row.needsUpload = row.envelope?.key.kind.participatesInSync == true
            row.systemFieldsData = nil
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    public func markAllEntriesNeedsUploadAfterEnvironmentChange() throws {
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

    private func preferred(_ first: SettingsEnvelope, _ second: SettingsEnvelope) throws -> SettingsEnvelope {
        if first.version != second.version {
            return first.version < second.version ? second : first
        }
        let firstData = try SettingsSyncCodec.encode(first)
        let secondData = try SettingsSyncCodec.encode(second)
        return firstData.lexicographicallyPrecedes(secondData) ? second : first
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

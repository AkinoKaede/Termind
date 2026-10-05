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
        // Preserve tombstone acknowledgement state. The scoped physical-deletion sidecar
        // schedules an unconfirmed historical tombstone even when needsUpload is false.
        if !legacyEnvelope.isDeleted {
            context.delete(legacyRow)
        }
        if canonicalChanged || !legacyEnvelope.isDeleted {
            let syncState = try state()
            syncState.engineStateData = nil
        }
        return SettingsMutationSet(keys: canonicalChanged ? [canonicalKey] : [])
    }

    /// Removes records that are retained only for wire compatibility. Resetting
    /// the engine state also drops any pending save for those records without
    /// creating a CloudKit deletion.
    public func discardInactiveEntries() throws {
        let rows = try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).filter {
            // Highlight payloads are retired, including malformed data and old tombstones.
            if $0.kind == SettingsRecordKind.terminalHighlighting.rawValue
                || SettingsRecordKey(recordName: $0.recordName)?.kind == .terminalHighlighting
            {
                return true
            }
            return $0.envelope.map { !$0.key.kind.participatesInSync && !$0.isDeleted } == true
        }
        if !rows.isEmpty {
            for row in rows { context.delete(row) }
            let syncState = try state()
            syncState.engineStateData = nil
        }
    }

    /// Clears the synchronized replica while retaining non-uploadable tombstone sentinels
    /// for singleton defaults that `prepare()` otherwise adds automatically.
    public func purgeCloudCache() throws -> [CloudSyncMutation] {
        let state = try state()
        var suppressed: [CloudSyncMutation] = []
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            context.delete(row)
        }
        for key in [
            SettingsRecordKey(kind: .webSearch, id: "default"),
            SettingsRecordKey(kind: .terminal, id: "default"),
            SettingsRecordKey(kind: .ssh, id: "default"),
            SettingsRecordKey(kind: .sftp, id: "default"),
            SettingsRecordKey(kind: .workspace, id: "default"),
            SettingsRecordKey(kind: .notifications, id: "default"),
        ] {
            let envelope = SettingsEnvelope(
                key: key, version: .baseline(writerID: state.installationID), isDeleted: true)
            context.insert(try PersistentAIConfigurationSyncEntry(envelope: envelope, needsUpload: false))
            suppressed.append(
                CloudSyncMutation(recordName: key.recordName, operation: .delete, version: envelope.version))
        }
        state.bootstrapCompleted = true
        state.engineStateData = nil
        state.pendingUserRecordName = nil
        state.lastSuccessfulSync = nil
        return suppressed
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

    public func outgoingEntry(for key: SettingsRecordKey, scope: CloudSyncScope? = nil) throws -> SettingsOutgoingEntry?
    {
        if let scope,
            try CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: key.recordName)
        {
            return nil
        }
        guard key.kind.participatesInSync else { return nil }
        guard let row = try entry(recordName: key.recordName), row.needsUpload, let envelope = row.envelope,
            !envelope.isDeleted
        else {
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
            if local.isDeleted && !envelope.isDeleted && entries[envelope.key.recordName]?.needsUpload == true {
                result.needsUpload.insert(local.key)
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
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version, row.needsUpload else {
            return
        }
        row.needsUpload = false
    }

    public func queueHistoricalDeletion(_ envelope: SettingsEnvelope) throws {
        guard envelope.isDeleted,
            !envelope.key.kind.participatesInSync || envelope.key.isLegacyGuardianRole
        else { return }
        var entries = try entriesByName()
        try store(envelope, needsUpload: true, in: &entries)
        try updateSystemFields(nil, for: envelope.key)
    }

    public func clearSystemFields(recordName: String) throws {
        try entry(recordName: recordName)?.systemFieldsData = nil
    }

    public func updateSystemFields(_ data: Data?, for key: SettingsRecordKey) throws {
        guard let row = try entry(recordName: key.recordName), row.systemFieldsData != data else { return }
        row.systemFieldsData = data
    }

    public func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()) {
            guard let envelope = row.envelope else { continue }
            guard envelope.key.kind.participatesInSync else {
                context.delete(row)
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
            if row.envelope?.isDeleted == true && !envelope.isDeleted { row.systemFieldsData = nil }
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

extension SettingsSyncJournal {
    public func cloudRecords() throws -> [CloudSyncJournalRecord] {
        try context.fetch(FetchDescriptor<PersistentAIConfigurationSyncEntry>()).compactMap { row in
            guard let envelope = row.envelope else { return nil }
            let key = envelope.key
            guard key.kind.participatesInSync || envelope.isDeleted else { return nil }
            return CloudSyncJournalRecord(
                recordName: key.recordName, version: envelope.version, isDeleted: envelope.isDeleted,
                needsUpload: row.needsUpload, hasSystemFields: row.systemFieldsData != nil)
        }
    }

    public func deletionEnvelopes(_ keys: Set<SettingsRecordKey>) throws -> [SettingsEnvelope] {
        try keys.compactMap { key in
            guard key.kind.participatesInSync else { return nil }
            let row = try entry(recordName: key.recordName)
            // Preserve undecodable local data until a compatible client can reconcile it.
            if let row, row.envelope == nil { return nil }
            let old = row?.envelope
            if let old, old.isDeleted { return old }
            return SettingsEnvelope(
                key: key, version: .next(after: old?.version, writerID: try state().installationID), isDeleted: true)
        }
    }

    public func acknowledgeDeletion(_ mutation: CloudSyncMutation, scope: CloudSyncScope) throws {
        guard let key = SettingsRecordKey(recordName: mutation.recordName),
            let row = try entry(recordName: mutation.recordName), let envelope = row.envelope
        else { return }
        guard key.kind.participatesInSync || envelope.isDeleted else { return }
        if !envelope.isDeleted && row.needsUpload && mutation.version < envelope.version {
            // A later explicit recreation is still pending; acknowledge only the old server incarnation.
            try updateSystemFields(nil, for: key)
            try CloudSyncRecordStateStore(context: context, scope: scope).deleted(
                key.recordName, version: mutation.version)
            return
        }
        guard envelope.isDeleted, envelope.version == mutation.version else { return }
        try markUploaded(key, version: mutation.version)
        try updateSystemFields(nil, for: key)
        try CloudSyncRecordStateStore(context: context, scope: scope).deleted(key.recordName, version: mutation.version)
    }
}

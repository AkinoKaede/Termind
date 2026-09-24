import Foundation
import SwiftData
import TermindApplication
import TermindDomain

public nonisolated struct MetricsRemoteMerge: Sendable {
    public var accepted: [MetricsEnvelope] = []
    public var needsUpload: Set<MetricsRecordKey> = []
}

public nonisolated struct MetricsOutgoingEntry: Sendable {
    public var envelope: MetricsEnvelope
    public var systemFieldsData: Data?

    public init(envelope: MetricsEnvelope, systemFieldsData: Data? = nil) {
        self.envelope = envelope
        self.systemFieldsData = systemFieldsData
    }
}

@MainActor
public final class MetricsSyncJournal {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func state() throws -> PersistentMetricsSyncState {
        var descriptor = FetchDescriptor<PersistentMetricsSyncState>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let state = PersistentMetricsSyncState()
        context.insert(state)
        return state
    }

    @discardableResult
    public func bootstrapIfNeeded(_ snapshot: MetricsSyncSnapshot) throws -> MetricsMutationSet {
        let state = try state()
        guard !state.bootstrapCompleted else { return .empty }
        var entries = try entriesByName()
        var changed = Set<MetricsRecordKey>()
        for payload in snapshot.recordPayloads.values {
            let key = payload.key
            guard entries[key.recordName] == nil else { continue }
            let envelope = MetricsEnvelope(
                key: key, version: .baseline(writerID: state.installationID), payload: payload)
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }
        state.bootstrapCompleted = true
        return MetricsMutationSet(keys: changed)
    }

    public func recordLocalChanges(
        from oldSnapshot: MetricsSyncSnapshot, to newSnapshot: MetricsSyncSnapshot,
        now: Date = .now
    ) throws -> MetricsMutationSet {
        let state = try state()
        let old = oldSnapshot.recordPayloads
        let new = newSnapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<MetricsRecordKey>()

        for (key, payload) in new where old[key] != payload {
            let row = entries[key.recordName]
            let envelope = MetricsEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload)
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }

        for key in old.keys where new[key] == nil {
            let row = entries[key.recordName]
            let envelope = MetricsEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                isDeleted: true)
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }
        return MetricsMutationSet(keys: changed)
    }

    public func pendingEnvelopes() throws -> [MetricsEnvelope] {
        try context.fetch(
            FetchDescriptor<PersistentMetricsSyncEntry>(predicate: #Predicate { $0.needsUpload })
        ).compactMap(\.envelope)
    }

    public func importLegacyQuarantine(into scope: CloudSyncScope) throws {
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        for row in try context.fetch(FetchDescriptor<PersistentMetricsSyncQuarantine>()) {
            if try !safety.isUploadBlocked(recordName: row.recordName) {
                try safety.quarantine(recordName: row.recordName, payloadData: row.payloadData, reason: row.reason)
            }
            context.delete(row)
        }
    }

    public func outgoingEntry(for key: MetricsRecordKey, scope: CloudSyncScope? = nil) throws -> MetricsOutgoingEntry? {
        if let scope,
            try CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: key.recordName)
        {
            return nil
        }
        guard let row = try entry(recordName: key.recordName), row.needsUpload, let envelope = row.envelope,
            !envelope.isDeleted
        else {
            return nil
        }
        return MetricsOutgoingEntry(envelope: envelope, systemFieldsData: row.systemFieldsData)
    }

    public func envelope(for key: MetricsRecordKey) throws -> MetricsEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }

    public func mergeDecision(for remote: [MetricsEnvelope]) throws -> MetricsRemoteMerge {
        var result = MetricsRemoteMerge()
        let entries = try entriesByName()
        var candidates: [MetricsRecordKey: MetricsEnvelope] = [:]
        for envelope in remote {
            guard envelope.isValid else {
                throw MetricsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            if let previous = candidates[envelope.key] {
                if envelope.version < previous.version { continue }
                let previousData = try MetricsSyncCodec.encode(previous)
                let incomingData = try MetricsSyncCodec.encode(envelope)
                if envelope.version == previous.version,
                    !previousData.lexicographicallyPrecedes(incomingData)
                {
                    continue
                }
            }
            candidates[envelope.key] = envelope
        }

        for envelope in candidates.values {
            guard envelope.formatVersion <= MetricsEnvelope.currentFormatVersion else {
                throw MetricsSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
            }
            guard envelope.isValid else {
                throw MetricsSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            guard let local = entries[envelope.key.recordName]?.envelope else {
                result.accepted.append(envelope)
                continue
            }
            if local.isDeleted && !envelope.isDeleted && entries[envelope.key.recordName]?.needsUpload == true {
                result.needsUpload.insert(local.key)
                continue
            }
            if local.version.modifiedAt == VaultVersion.baselineDate, !local.isDeleted, local != envelope {
                result.accepted.append(envelope)
            } else if local.version < envelope.version {
                result.accepted.append(envelope)
            } else if envelope.version < local.version {
                result.needsUpload.insert(local.key)
            } else if local != envelope {
                let localData = try MetricsSyncCodec.encode(local)
                let remoteData = try MetricsSyncCodec.encode(envelope)
                if localData.lexicographicallyPrecedes(remoteData) {
                    result.accepted.append(envelope)
                } else {
                    result.needsUpload.insert(local.key)
                }
            }
        }
        return result
    }

    public func acceptRemote(_ envelopes: [MetricsEnvelope]) throws {
        var entries = try entriesByName()
        for envelope in envelopes { try store(envelope, needsUpload: false, in: &entries) }
    }

    public func markNeedsUpload(_ keys: Set<MetricsRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys { entries[key.recordName]?.needsUpload = true }
    }

    public func markUploaded(_ key: MetricsRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version, row.needsUpload else {
            return
        }
        row.needsUpload = false
    }

    public func updateSystemFields(_ data: Data?, for key: MetricsRecordKey) throws {
        guard let row = try entry(recordName: key.recordName), row.systemFieldsData != data else { return }
        row.systemFieldsData = data
    }

    public func clearSystemFields(recordName: String) throws {
        try entry(recordName: recordName)?.systemFieldsData = nil
    }

    public func quarantine(recordName: String, payloadData: Data, reason: String) throws {
        var descriptor = FetchDescriptor<PersistentMetricsSyncQuarantine>(
            predicate: #Predicate { $0.recordName == recordName })
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first {
            row.payloadData = payloadData
            row.reason = reason
            row.receivedAt = .now
        } else {
            context.insert(
                PersistentMetricsSyncQuarantine(
                    recordName: recordName, payloadData: payloadData, reason: reason))
        }
    }

    public func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()) {
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

    public func markAllEntriesNeedsUploadAfterZoneReset() throws {
        for row in try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()) {
            row.needsUpload = true
            row.systemFieldsData = nil
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    public func markAllEntriesNeedsUploadAfterEnvironmentChange() throws {
        try markAllEntriesNeedsUploadAfterZoneReset()
    }

    private func entry(recordName: String) throws -> PersistentMetricsSyncEntry? {
        var descriptor = FetchDescriptor<PersistentMetricsSyncEntry>(
            predicate: #Predicate { $0.recordName == recordName })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func store(
        _ envelope: MetricsEnvelope, needsUpload: Bool,
        in entries: inout [String: PersistentMetricsSyncEntry]
    ) throws {
        if let row = entries[envelope.key.recordName] {
            if row.envelope?.isDeleted == true && !envelope.isDeleted { row.systemFieldsData = nil }
            try row.apply(envelope, needsUpload: needsUpload)
        } else {
            let row = try PersistentMetricsSyncEntry(envelope: envelope, needsUpload: needsUpload)
            context.insert(row)
            entries[envelope.key.recordName] = row
        }
    }

    private func entriesByName() throws -> [String: PersistentMetricsSyncEntry] {
        Dictionary(
            try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()).map { ($0.recordName, $0) },
            uniquingKeysWith: { first, duplicate in
                if let firstVersion = first.envelope?.version,
                    let duplicateVersion = duplicate.envelope?.version,
                    firstVersion < duplicateVersion
                {
                    return duplicate
                }
                return first
            })
    }
}

@MainActor
public final class MetricsSyncPersistence: MetricsConfigurationStoring {
    public let context: ModelContext
    public let journal: MetricsSyncJournal
    private let defaults: UserDefaults
    public var didRecordChanges: ((MetricsMutationSet) -> Void)?

    public init(context: ModelContext, defaults: UserDefaults = .standard) {
        self.context = context
        self.defaults = defaults
        journal = MetricsSyncJournal(context: context)
    }

    public func prepare() throws {
        var mutations = MetricsMutationSet.empty
        try context.commit {
            let state = try journal.state()
            guard !state.bootstrapCompleted else { return }
            mutations = try journal.bootstrapIfNeeded(MetricsSyncSnapshot(selections: legacySelections()))
        }
        didRecordChanges?(mutations)
    }

    public func purgeCloudCache(
        scope: CloudSyncScope, assetCleanupKey: String? = nil
    ) throws -> (MetricsSyncSnapshot, Set<MetricsRecordKey>) {
        var removed = Set<MetricsRecordKey>()
        try context.commit {
            removed = Set(
                try journal.cloudRecords().compactMap { MetricsRecordKey(recordName: $0.mutation.recordName) })
            for row in try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()) { context.delete(row) }
            let state = try journal.state()
            state.bootstrapCompleted = true
            state.engineStateData = nil
            state.pendingUserRecordName = nil
            state.lastSuccessfulSync = nil
            try CloudSyncSafetyStore(context: context, scope: scope).purgeScope()
            try CloudSyncRecordStateStore(context: context, scope: scope).purgeScope()
            if let assetCleanupKey {
                try CloudSyncAssetCleanupStore(context: context).markPending(
                    scope: scope, cacheKey: assetCleanupKey)
            }
        }
        return (MetricsSyncSnapshot(), removed)
    }

    public func load() throws -> [MetricsSelection] { try materialize().selections }

    public func save(_ selections: [MetricsSelection]) throws {
        var mutations = MetricsMutationSet.empty
        try context.commit {
            let previous = try materialize()
            try journal.bootstrapIfNeeded(previous)
            mutations = try journal.recordLocalChanges(
                from: previous, to: MetricsSyncSnapshot(selections: Self.deduplicated(selections)))
        }
        didRecordChanges?(mutations)
    }

    public func applyRemote(
        _ envelopes: [MetricsEnvelope], deletions: Set<MetricsRecordKey> = [],
        beforeSave: () throws -> Void = {}
    ) throws
        -> (snapshot: MetricsSyncSnapshot, acceptedKeys: Set<MetricsRecordKey>, needsUpload: Set<MetricsRecordKey>)
    {
        var merge = MetricsRemoteMerge()
        var snapshot = try materialize()
        try context.commit(beforeSave: beforeSave) {
            let deleted = try journal.deletionEnvelopes(deletions)
            merge = try journal.mergeDecision(for: envelopes.filter { !deletions.contains($0.key) } + deleted)
            guard !merge.accepted.isEmpty else {
                try journal.markNeedsUpload(merge.needsUpload)
                return
            }
            try journal.acceptRemote(merge.accepted)
            snapshot = try materialize()
            try journal.markNeedsUpload(merge.needsUpload)
        }
        return (snapshot, Set(merge.accepted.map(\.key)), merge.needsUpload)
    }

    private func materialize() throws -> MetricsSyncSnapshot {
        var rows: [SyncedMetricsSelection] = []
        for row in try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()) {
            guard let envelope = row.envelope, !envelope.isDeleted else { continue }
            if case .selection(let value) = envelope.payload { rows.append(value) }
        }
        rows.sort {
            ($0.sortIndex, $0.selection.id.uuidString) < ($1.sortIndex, $1.selection.id.uuidString)
        }
        return MetricsSyncSnapshot(selections: Self.deduplicated(rows.map(\.selection)))
    }

    private func legacySelections() -> [MetricsSelection] {
        let keys = ["metrics.servers", "mobile.metrics.v1"]
        return Self.deduplicated(
            keys.flatMap { key -> [MetricsSelection] in
                guard let data = defaults.data(forKey: key) else { return [] }
                return (try? JSONDecoder().decode([MetricsSelection].self, from: data)) ?? []
            })
    }

    private static func deduplicated(_ values: [MetricsSelection]) -> [MetricsSelection] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0.id).inserted }
    }
}

extension MetricsSyncJournal {
    public func cloudRecords() throws -> [CloudSyncJournalRecord] {
        try context.fetch(FetchDescriptor<PersistentMetricsSyncEntry>()).compactMap { row in
            guard let envelope = row.envelope else { return nil }
            let key = envelope.key
            return CloudSyncJournalRecord(
                recordName: key.recordName, version: envelope.version, isDeleted: envelope.isDeleted,
                needsUpload: row.needsUpload, hasSystemFields: row.systemFieldsData != nil)
        }
    }

    public func deletionEnvelopes(_ keys: Set<MetricsRecordKey>) throws -> [MetricsEnvelope] {
        try keys.compactMap { key in
            let row = try entry(recordName: key.recordName)
            // Preserve undecodable local data until a compatible client can reconcile it.
            if let row, row.envelope == nil { return nil }
            let old = row?.envelope
            if let old, old.isDeleted { return old }
            return MetricsEnvelope(
                key: key, version: .next(after: old?.version, writerID: try state().installationID), isDeleted: true)
        }
    }

    public func acknowledgeDeletion(_ mutation: CloudSyncMutation, scope: CloudSyncScope) throws {
        guard let key = MetricsRecordKey(recordName: mutation.recordName),
            let row = try entry(recordName: mutation.recordName), let envelope = row.envelope
        else { return }
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

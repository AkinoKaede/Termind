import Foundation
import SwiftData
import TermindApplication
import TermindDomain

public nonisolated struct HistoryOutgoingEntry: Sendable {
    public var envelope: HistoryEnvelope
    public var systemFieldsData: Data?
    public init(envelope: HistoryEnvelope, systemFieldsData: Data? = nil) {
        self.envelope = envelope
        self.systemFieldsData = systemFieldsData
    }
}

/// Owns events, device projections, and their replication journal as one transaction.
/// Callers that already own a ModelContext transaction use the journal methods directly.
@MainActor
public final class HistorySyncPersistence {
    public let context: ModelContext
    public let journal: HistorySyncJournal
    public init(context: ModelContext) {
        self.context = context
        journal = HistorySyncJournal(context: context)
    }

    public func prepare() throws {
        try context.commit {
            try restoreMissingDeviceRecords()
            try journal.bootstrapIfNeeded()
            try prune()
            _ = try journal.recordCurrentSnapshot()
        }
    }

    /// A fetched record never echoes back just for being read.
    public func applyRemote(
        _ envelopes: [HistoryEnvelope], deletions: Set<HistoryRecordKey> = [],
        beforeSave: () throws -> Void = {}
    ) throws -> Set<HistoryRecordKey> {
        var changed = Set<HistoryRecordKey>()
        try context.commit {
            try journal.bootstrapIfNeeded()
            let deleted = try journal.deletionEnvelopes(deletions)
            for remote in envelopes.filter({ !deletions.contains($0.key) }) + deleted {
                guard remote.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(remote.key.recordName) }
                let local = try journal.envelope(for: remote.key)
                let accept: Bool
                if remote.key.kind == .connectionHistory, let local, local.isDeleted != remote.isDeleted {
                    // Event IDs are never reused. Deletion is terminal even if a delayed
                    // end-time update has a later clock; otherwise Clear History resurrects.
                    accept = remote.isDeleted
                } else if let local {
                    if local.version == remote.version {
                        accept = try HistorySyncCodec.encode(local).lexicographicallyPrecedes(
                            HistorySyncCodec.encode(remote))
                    } else {
                        accept = local.version < remote.version
                    }
                } else {
                    accept = true
                }
                if accept {
                    try apply(remote)
                    try journal.store(remote, needsUpload: false)
                    changed.insert(remote.key)
                } else if let local {
                    if local != remote { try journal.markNeedsUpload([local.key]) }
                    // A replay can have the same version even when the local directory projection is missing.
                    if case .device(let device) = local.payload, try restoreMissingDevice(device) {
                        changed.insert(local.key)
                    }
                }
            }
            try prune()
            _ = try journal.recordCurrentSnapshot()
            try beforeSave()
        }
        return changed
    }

    private func apply(_ envelope: HistoryEnvelope) throws {
        let id = envelope.key.id
        switch envelope.key.kind {
        case .connectionHistory:
            let existing = try context.fetch(
                FetchDescriptor<PersistentConnectionHistoryEntry>(
                    predicate: #Predicate { $0.id == id })
            ).first
            if envelope.isDeleted {
                if let existing { context.delete(existing) }
                return
            }
            guard case .connectionHistory(let value) = envelope.payload else {
                throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            if let existing { existing.apply(value) } else { context.insert(PersistentConnectionHistoryEntry(value)) }
        case .device:
            let existing = try context.fetch(
                FetchDescriptor<PersistentDeviceRecord>(
                    predicate: #Predicate { $0.id == id })
            ).first
            if envelope.isDeleted {
                if let existing { context.delete(existing) }
                return
            }
            guard case .device(let value) = envelope.payload else {
                throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            if let existing {
                existing.displayName = value.displayName
            } else {
                context.insert(PersistentDeviceRecord(value))
            }
        }
    }

    private func restoreMissingDeviceRecords() throws {
        for row in try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>()) {
            guard let envelope = row.envelope, !envelope.isDeleted,
                case .device(let device) = envelope.payload
            else { continue }
            _ = try restoreMissingDevice(device)
        }
    }

    private func restoreMissingDevice(_ device: DeviceRecord) throws -> Bool {
        let id = device.id
        let descriptor = FetchDescriptor<PersistentDeviceRecord>(predicate: #Predicate { $0.id == id })
        guard try context.fetch(descriptor).isEmpty else { return false }
        context.insert(PersistentDeviceRecord(device))
        return true
    }

    private func prune() throws {
        let rows = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .sorted { ConnectionHistoryEntry.isNewer($0.value, $1.value) }
        for row in rows.dropFirst(ConnectionHistoryModel.limit) { context.delete(row) }
    }
}

@MainActor
public final class HistorySyncJournal {
    private let context: ModelContext
    private let kind: HistoryRecordKind?
    public init(context: ModelContext, kind: HistoryRecordKind? = nil) {
        self.context = context
        self.kind = kind
    }

    public func state() throws -> PersistentHistorySyncState {
        let key = kind == .device ? "device-sync" : "history-sync"
        if let row = try context.fetch(
            FetchDescriptor<PersistentHistorySyncState>(predicate: #Predicate { $0.key == key })
        ).first {
            return row
        }
        let row = PersistentHistorySyncState()
        row.key = key
        if kind == .device {
            // Splitting the current native journal retains account consent, not the old engine cursor.
            let history = try HistorySyncJournal(context: context, kind: .connectionHistory).state()
            row.boundUserRecordName = history.boundUserRecordName
            row.pendingUserRecordName = history.pendingUserRecordName
        }
        context.insert(row)
        return row
    }

    public func bootstrapIfNeeded() throws {
        guard kind != nil else {
            for kind in HistoryRecordKind.allCases {
                try HistorySyncJournal(context: context, kind: kind).bootstrapIfNeeded()
            }
            return
        }
        let state = try state()
        guard !state.bootstrapCompleted else { return }
        for payload in try currentPayloads() where try entry(recordName: payload.key.recordName) == nil {
            try store(
                HistoryEnvelope(
                    key: payload.key, version: .baseline(writerID: state.installationID),
                    payload: payload), needsUpload: true)
        }
        state.bootstrapCompleted = true
    }

    @discardableResult
    public func recordCurrentSnapshot(now: Date = .now) throws -> HistoryMutationSet {
        try bootstrapIfNeeded()
        let payloads = try currentPayloads()
        let liveKeys = Set(payloads.map(\.key))
        var changed = Set<HistoryRecordKey>()
        for payload in payloads {
            let state = try HistorySyncJournal(context: context, kind: payload.key.kind).state()
            let row = try entry(recordName: payload.key.recordName)
            // An unsupported old journal must remain intact for upgrade/recovery.
            // Local rows retain edits, but cannot replace the only copy of unknown data.
            if let row, row.envelope == nil { continue }
            let old = row?.envelope
            if old?.payload == payload && old?.isDeleted == false { continue }
            if payload.key.kind == .connectionHistory, old?.isDeleted == true {
                throw VaultSyncPersistenceError.invalidEnvelope(payload.key.recordName)
            }
            try store(
                HistoryEnvelope(
                    key: payload.key,
                    version: .next(after: old?.version, writerID: state.installationID, now: now),
                    payload: payload), needsUpload: true)
            changed.insert(payload.key)
        }
        for row in try entries() {
            guard let old = row.envelope, old.key.kind == .connectionHistory,
                !old.isDeleted, !liveKeys.contains(old.key)
            else { continue }
            // Retain even never-uploaded tombstones: the same event can arrive again
            // from another device. Directory rows are not subject to event retention.
            try store(
                HistoryEnvelope(
                    key: old.key,
                    version: .next(after: old.version, writerID: try state().installationID, now: now),
                    isDeleted: true), needsUpload: true)
            changed.insert(old.key)
        }
        return HistoryMutationSet(keys: changed)
    }

    public func pendingEnvelopes() throws -> [HistoryEnvelope] {
        try entries().filter(\.needsUpload).compactMap(\.envelope)
    }
    public func uploadablePendingRecordNames(in scope: CloudSyncScope) throws -> [String] {
        let blocked = try CloudSyncSafetyStore(context: context, scope: scope).blockedRecordNames()
        return try entries().filter {
            $0.needsUpload && !blocked.contains($0.recordName)
        }.map(\.recordName)
    }
    public func outgoingEntry(for key: HistoryRecordKey, scope: CloudSyncScope) throws -> HistoryOutgoingEntry? {
        guard try !CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: key.recordName),
            let row = try entry(recordName: key.recordName), row.needsUpload, row.envelope?.isDeleted == false
        else { return nil }
        return HistoryOutgoingEntry(
            envelope: try HistorySyncCodec.decode(row.envelopeData), systemFieldsData: row.systemFieldsData)
    }
    public func envelope(for key: HistoryRecordKey) throws -> HistoryEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }
    public func store(_ envelope: HistoryEnvelope, needsUpload: Bool) throws {
        if let row = try entry(recordName: envelope.key.recordName) {
            if row.envelope?.isDeleted == true && !envelope.isDeleted { row.systemFieldsData = nil }
            try row.apply(envelope, needsUpload: needsUpload)
        } else {
            context.insert(try PersistentHistorySyncEntry(envelope: envelope, needsUpload: needsUpload))
        }
    }
    public func markNeedsUpload(_ keys: Set<HistoryRecordKey>) throws {
        for key in keys { try entry(recordName: key.recordName)?.needsUpload = true }
    }
    public func markUploaded(_ key: HistoryRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version, row.needsUpload else {
            return
        }
        row.needsUpload = false
    }
    public func updateSystemFields(_ data: Data?, for key: HistoryRecordKey) throws {
        guard let row = try entry(recordName: key.recordName), row.systemFieldsData != data else { return }
        row.systemFieldsData = data
    }

    public func resetForNewAccount() throws {
        for row in try entries() {
            if row.envelope?.isDeleted == true {
                context.delete(row)
            } else {
                row.needsUpload = true
                row.systemFieldsData = nil
            }
        }
        try resetState()
    }
    public func resetForZone() throws {
        for row in try entries() {
            row.needsUpload = true
            row.systemFieldsData = nil
        }
        try resetState()
    }
    private func resetState() throws {
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }
    private func entry(recordName: String) throws -> PersistentHistorySyncEntry? {
        try context.fetch(
            FetchDescriptor<PersistentHistorySyncEntry>(predicate: #Predicate { $0.recordName == recordName })
        ).first
    }
    private func entries() throws -> [PersistentHistorySyncEntry] {
        try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>()).filter {
            kind == nil || HistoryRecordKey(recordName: $0.recordName)?.kind == kind
        }
    }
    private func currentPayloads() throws -> [HistoryRecordPayload] {
        let payloads: [HistoryRecordPayload] =
            try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).map { .connectionHistory($0.value) }
            + context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map { .device($0.value) }
        return payloads.filter { kind == nil || $0.key.kind == kind }
    }
}

extension HistorySyncJournal {
    public func cloudRecords() throws -> [CloudSyncJournalRecord] {
        try entries().compactMap { row in
            guard let envelope = row.envelope else { return nil }
            let key = envelope.key
            guard kind == nil || key.kind == kind else { return nil }
            return CloudSyncJournalRecord(
                recordName: key.recordName, version: envelope.version, isDeleted: envelope.isDeleted,
                needsUpload: row.needsUpload, hasSystemFields: row.systemFieldsData != nil)
        }
    }

    public func deletionEnvelopes(_ keys: Set<HistoryRecordKey>) throws -> [HistoryEnvelope] {
        try keys.compactMap { key in
            guard kind == nil || key.kind == kind else { return nil }
            let row = try entry(recordName: key.recordName)
            // Preserve undecodable local data until a compatible client can reconcile it.
            if let row, row.envelope == nil { return nil }
            let old = row?.envelope
            if let old, old.isDeleted { return old }
            return HistoryEnvelope(
                key: key, version: .next(after: old?.version, writerID: try state().installationID), isDeleted: true)
        }
    }

    public func acknowledgeDeletion(_ mutation: CloudSyncMutation, scope: CloudSyncScope) throws {
        guard let key = HistoryRecordKey(recordName: mutation.recordName), kind == nil || key.kind == kind,
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

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
            try journal.bootstrapIfNeeded()
            try prune()
            _ = try journal.recordCurrentSnapshot()
        }
    }

    /// Legacy imports retain the original version but acquire upload intent in the
    /// destination zone. A fetched destination record never echoes back just for being read.
    public func applyRemote(
        _ envelopes: [HistoryEnvelope], importingLegacy: Bool = false,
        beforeSave: () throws -> Void = {}
    ) throws -> Set<HistoryRecordKey> {
        var changed = Set<HistoryRecordKey>()
        try context.commit {
            try journal.bootstrapIfNeeded()
            for remote in envelopes {
                guard remote.isValid else { throw VaultSyncPersistenceError.invalidEnvelope(remote.key.recordName) }
                let local = try journal.envelope(for: remote.key)
                let accept: Bool
                if remote.key.kind == .connectionHistory, let local, local.isDeleted != remote.isDeleted {
                    // Event IDs are never reused. Deletion is terminal even if a delayed
                    // legacy end-time update has a later clock; otherwise Clear History resurrects.
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
                    try journal.store(remote, needsUpload: importingLegacy)
                    changed.insert(remote.key)
                } else if !importingLegacy, let local, local != remote {
                    try journal.markNeedsUpload([local.key])
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

    private func prune() throws {
        let rows = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .sorted { ConnectionHistoryEntry.isNewer($0.value, $1.value) }
        for row in rows.dropFirst(ConnectionHistoryModel.limit) { context.delete(row) }
    }
}

@MainActor
public final class HistorySyncJournal {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }

    public func state() throws -> PersistentHistorySyncState {
        if let row = try context.fetch(FetchDescriptor<PersistentHistorySyncState>()).first { return row }
        let legacy = try VaultSyncJournal(context: context).state()
        let row = PersistentHistorySyncState()
        row.installationID = legacy.installationID
        // Inherit consent provenance. Moving local data to another category must
        // not silently authorize sending a previous account's data to a new account.
        row.boundUserRecordName = legacy.boundUserRecordName
        row.pendingUserRecordName = legacy.pendingUserRecordName
        context.insert(row)
        return row
    }

    public func bootstrapIfNeeded() throws {
        let state = try state()
        guard !state.bootstrapCompleted else { return }
        for legacy in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) {
            guard HistoryRecordKey(recordName: legacy.recordName) != nil,
                try entry(recordName: legacy.recordName) == nil
            else { continue }
            // The wire shape is unchanged in History V1. Preserve unreadable bytes as
            // well as tombstones; safety preparation fences them before any upload.
            let row = PersistentHistorySyncEntry(recordName: legacy.recordName, data: legacy.envelopeData)
            context.insert(row)
        }
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
        let state = try state()
        let payloads = try currentPayloads()
        let liveKeys = Set(payloads.map(\.key))
        var changed = Set<HistoryRecordKey>()
        for payload in payloads {
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
            // from a legacy device. Directory rows are not subject to event retention.
            try store(
                HistoryEnvelope(
                    key: old.key,
                    version: .next(after: old.version, writerID: state.installationID, now: now),
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
        let legacyBlocked = try CloudSyncSafetyStore(context: context, scope: scope.historyImportScope)
            .blockedRecordNames()
        return try entries().filter {
            $0.needsUpload && !blocked.contains($0.recordName)
                && !legacyBlocked.contains($0.recordName)
        }.map(\.recordName)
    }
    public func outgoingEntry(for key: HistoryRecordKey, scope: CloudSyncScope) throws -> HistoryOutgoingEntry? {
        guard try !CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: key.recordName),
            try !CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).isUploadBlocked(
                recordName: key.recordName),
            let row = try entry(recordName: key.recordName)
        else { return nil }
        return HistoryOutgoingEntry(
            envelope: try HistorySyncCodec.decode(row.envelopeData), systemFieldsData: row.systemFieldsData)
    }
    public func envelope(for key: HistoryRecordKey) throws -> HistoryEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }
    public func store(_ envelope: HistoryEnvelope, needsUpload: Bool) throws {
        if let row = try entry(recordName: envelope.key.recordName) {
            try row.apply(envelope, needsUpload: needsUpload)
        } else {
            context.insert(try PersistentHistorySyncEntry(envelope: envelope, needsUpload: needsUpload))
        }
    }
    public func markNeedsUpload(_ keys: Set<HistoryRecordKey>) throws {
        for key in keys { try entry(recordName: key.recordName)?.needsUpload = true }
    }
    public func markUploaded(_ key: HistoryRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version else { return }
        row.needsUpload = false
    }
    public func updateSystemFields(_ data: Data?, for key: HistoryRecordKey) throws {
        try entry(recordName: key.recordName)?.systemFieldsData = data
    }

    public func importLegacyQuarantine(into scope: CloudSyncScope) throws {
        let safety = CloudSyncSafetyStore(context: context, scope: scope.historyImportScope)
        for row in try entries() where row.envelope == nil {
            try safety.quarantine(
                recordName: row.recordName, payloadData: row.envelopeData,
                reason: "Unreadable migrated history journal", reasonCode: .unreadablePayload)
        }
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncQuarantine>())
        where HistoryRecordKey(recordName: row.recordName) != nil {
            if try !safety.isUploadBlocked(recordName: row.recordName) {
                try safety.quarantine(recordName: row.recordName, payloadData: row.payloadData, reason: row.reason)
            }
            context.delete(row)
        }
        // Preserve restrictions under their original account/environment, not the
        // account currently signed in when the app is upgraded.
        var vaultScope = scope
        vaultScope.zone = "TermindVaultV1"
        let old = CloudSyncSafetyStore(context: context, scope: vaultScope)
        let imported = CloudSyncSafetyStore(context: context, scope: scope.historyImportScope)
        for name in try old.blockedRecordNames() where HistoryRecordKey(recordName: name) != nil {
            guard let row = try old.entry(recordName: name) else { continue }
            try imported.quarantine(
                recordName: name, payloadData: row.payloadData, systemFieldsData: row.systemFieldsData,
                reason: row.reason,
                reasonCode: CloudSyncQuarantineReason(rawValue: row.reasonCode) ?? .unreadablePayload)
            try old.clearQuarantine(recordName: name)
        }
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
        try context.fetch(FetchDescriptor<PersistentHistorySyncEntry>())
    }
    private func currentPayloads() throws -> [HistoryRecordPayload] {
        try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>()).map { .connectionHistory($0.value) }
            + context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map { .device($0.value) }
    }
}

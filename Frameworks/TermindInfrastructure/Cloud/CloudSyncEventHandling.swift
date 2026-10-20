// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import TermindDomain

struct CloudSyncSentChanges {
    struct FailedSave {
        var record: CKRecord
        var error: CKError
    }

    var savedRecords: [CKRecord]
    var failedRecordSaves: [FailedSave]
    var deletedRecordIDs: [CKRecord.ID] = []
    var failedRecordDeletes: [CKRecord.ID: CKError] = [:]
}

extension CloudSyncSentChanges {
    init(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        self.init(
            savedRecords: changes.savedRecords,
            failedRecordSaves: changes.failedRecordSaves.map { FailedSave(record: $0.record, error: $0.error) },
            deletedRecordIDs: changes.deletedRecordIDs, failedRecordDeletes: changes.failedRecordDeletes)
    }
}

enum CloudSyncZoneDeletionReason: Sendable {
    case deleted
    case purged
    case encryptedDataReset
}

/// A constructible projection of the CKSyncEngine events used by writable sync categories.
/// Keeping this value separate from CloudKit's event constructors gives the shared dispatcher a deterministic test seam.
enum CloudSyncEventInput {
    case stateUpdate(CKSyncEngine.State.Serialization)
    case accountChange(CKSyncEngine.Event.AccountChange.ChangeType)
    case fetchedRecordZoneChanges(records: [CKRecord], deletions: [CKRecord.ID])
    case fetchedDatabaseChanges(deletions: [(zoneID: CKRecordZone.ID, reason: CloudSyncZoneDeletionReason)])
    case sentRecordZoneChanges(CloudSyncSentChanges)
    case willFetchChanges
    case willSendChanges
    case didFetchRecordZoneChanges(CKError?)
    case didFetchChanges
    case didSendChanges
    case ignored

    init(_ event: CKSyncEngine.Event) {
        switch event {
        case .stateUpdate(let update):
            self = .stateUpdate(update.stateSerialization)
        case .accountChange(let change):
            self = .accountChange(change.changeType)
        case .fetchedRecordZoneChanges(let changes):
            self = .fetchedRecordZoneChanges(
                records: changes.modifications.map(\.record), deletions: changes.deletions.map(\.recordID))
        case .fetchedDatabaseChanges(let changes):
            self = .fetchedDatabaseChanges(
                deletions: changes.deletions.map {
                    let reason: CloudSyncZoneDeletionReason
                    switch $0.reason {
                    case .deleted: reason = .deleted
                    case .purged: reason = .purged
                    case .encryptedDataReset: reason = .encryptedDataReset
                    @unknown default: reason = .purged
                    }
                    return ($0.zoneID, reason)
                })
        case .sentRecordZoneChanges(let changes):
            self = .sentRecordZoneChanges(CloudSyncSentChanges(changes))
        case .willFetchChanges:
            self = .willFetchChanges
        case .willSendChanges:
            self = .willSendChanges
        case .didFetchRecordZoneChanges(let changes):
            self = .didFetchRecordZoneChanges(changes.error)
        case .didFetchChanges:
            self = .didFetchChanges
        case .didSendChanges:
            self = .didSendChanges
        default:
            self = .ignored
        }
    }
}

extension CloudSyncLifecycle {
    func handle(
        _ event: CloudSyncEventInput, engine: any CloudSyncEngineSession,
        receiveRemoteRecords: @MainActor ([CKRecord], [CKRecord.ID]) throws -> Void,
        handleSentChanges: @MainActor (CloudSyncSentChanges) throws -> Void
    ) {
        guard accepts(engine) else { return }
        do {
            switch event {
            case .stateUpdate(let serialization):
                try saveEngineState(serialization)
            case .accountChange(let change):
                try handleAccountChange(change)
            case .fetchedRecordZoneChanges(let records, let deletions):
                try receiveRemoteRecords(records, deletions)
            case .fetchedDatabaseChanges(let deletions):
                if let deletion = deletions.first(where: { $0.zoneID == zoneID }) {
                    try handleZoneDeletion(reason: deletion.reason)
                }
            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes)
            case .willFetchChanges:
                try beginFetch()
            case .willSendChanges:
                try beginSend()
            case .didFetchRecordZoneChanges(let error):
                if let error {
                    if error.code == .changeTokenExpired {
                        restartAfterExpiredToken()
                        return
                    }
                    guard Self.isRetryable(error) else { throw error }
                    noteFetchFailure(error)
                }
            case .didFetchChanges:
                try finishFetch()
                try updateUpToDateStatus()
            case .didSendChanges:
                try finishSend()
                try updateUpToDateStatus()
            case .ignored:
                break
            }
        } catch {
            failClosed(error)
        }
    }

    func handleFailedSave(
        _ error: CKError, receiveRemoteRecords: @MainActor ([CKRecord], Bool) throws -> Void
    ) throws {
        if error.code == .serverRecordChanged {
            guard let serverRecord = error.serverRecord else { throw error }
            try receiveRemoteRecords([serverRecord], true)
        } else if error.code == .zoneNotFound {
            try handleZoneDeletion()
        } else if !Self.isRetryable(error) {
            logFailure(error, stage: "save")
            terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    func handleDeletedRecords(
        _ changes: CloudSyncSentChanges, acknowledge: (CloudSyncMutation) throws -> Void
    ) throws {
        guard let scope else { throw CancellationError() }
        // A save result proves that the ID exists after any previously handed-off delete.
        noteRecordsObserved(changes.savedRecords)
        // A delete of an already missing record succeeded as far as this replica is concerned.
        let deleted =
            changes.deletedRecordIDs
            + changes.failedRecordDeletes.filter { $0.value.code == .unknownItem }.map(\.key)
        for id in deleted where id.zoneID == zoneID {
            guard let mutation = takeDeletionAcknowledgement(id),
                try !store.safety.isUploadBlocked(scope, id.recordName)
            else { continue }
            try acknowledge(mutation)
        }
        for (id, error) in changes.failedRecordDeletes where id.zoneID == zoneID && error.code != .unknownItem {
            let mutation = takeDeletionAcknowledgement(id)
            if error.code == .zoneNotFound {
                try handleZoneDeletion()
            } else if Self.isRetryable(error) || Self.isCancellation(error) {
                // The server may have committed an ambiguous delete. Release only
                // the in-memory causal slot so it can retry; keep the durable fence.
            } else {
                if let mutation { try cancelDeletionHandoff(mutation) }
                logFailure(error, stage: "delete")
                terminalError = error.localizedDescription
                status = .failed(error.localizedDescription)
            }
        }
    }
}

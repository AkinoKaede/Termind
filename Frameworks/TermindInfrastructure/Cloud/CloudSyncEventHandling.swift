import CloudKit

struct CloudSyncSentChanges {
    struct FailedSave {
        var record: CKRecord
        var error: CKError
    }

    var savedRecords: [CKRecord]
    var failedRecordSaves: [FailedSave]

    init(savedRecords: [CKRecord], failedRecordSaves: [FailedSave]) {
        self.savedRecords = savedRecords
        self.failedRecordSaves = failedRecordSaves
    }

    init(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        self.init(
            savedRecords: changes.savedRecords,
            failedRecordSaves: changes.failedRecordSaves.map { FailedSave(record: $0.record, error: $0.error) })
    }
}

/// A constructible projection of the CKSyncEngine events used by writable sync categories.
/// Keeping this value separate from CloudKit's event constructors gives the shared dispatcher a deterministic test seam.
enum CloudSyncEventInput {
    case stateUpdate(CKSyncEngine.State.Serialization)
    case accountChange(CKSyncEngine.Event.AccountChange.ChangeType)
    case fetchedRecordZoneChanges(records: [CKRecord], deletions: [CKRecord.ID])
    case fetchedDatabaseChanges(deletedZoneIDs: [CKRecordZone.ID])
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
            self = .fetchedDatabaseChanges(deletedZoneIDs: changes.deletions.map(\.zoneID))
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
            case .fetchedDatabaseChanges(let deletedZoneIDs):
                if deletedZoneIDs.contains(zoneID) { try handleZoneDeletion() }
            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes)
            case .willFetchChanges:
                try beginFetch()
            case .willSendChanges:
                try beginSend()
            case .didFetchRecordZoneChanges(let error):
                if let error {
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
}

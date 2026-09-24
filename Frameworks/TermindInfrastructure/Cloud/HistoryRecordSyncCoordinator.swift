import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

/// Shared record handling; each owner has its own engine, state, subscription and safety scope.
/// The cloud zone and record identities remain stable across coordinator changes.
@MainActor
@Observable
final class HistoryRecordSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    public nonisolated static let zoneName = "TermindConnectionHistoryV1"
    public nonisolated static let recordTypes = Set(HistoryRecordKind.allCases.map(\.recordType))

    private let context: ModelContext
    private let persistence: HistorySyncPersistence
    private let kind: HistoryRecordKind
    private let journal: HistorySyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    public private(set) var status: VaultSyncStatus {
        get { lifecycle.status }
        set { lifecycle.status = newValue }
    }
    public var didApplyRemote: ((Set<HistoryRecordKey>) -> Void)?

    public var isEnabled: Bool { lifecycle.isEnabled }
    private func includes(_ key: HistoryRecordKey) -> Bool { key.kind == kind }

    init(
        persistence: HistorySyncPersistence, kind: HistoryRecordKind,
        defaults: UserDefaults, environmentIdentifier: String,
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        self.kind = kind
        journal = HistorySyncJournal(context: persistence.context, kind: kind)
        self.makeTransport = makeTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()
    }

    public func configureLogging(_ logging: any ApplicationLogManaging) {
        lifecycle.logger = logging.makeLogger(label: "termind.cloud-sync")
    }

    public func start() {
        lifecycle.start()
    }
    public func setEnabled(_ enabled: Bool) { lifecycle.setEnabled(enabled) }
    public func pause() {
        lifecycle.pause()
    }
    public func retry() { lifecycle.retry() }
    public func confirmAccountSwitchMerge() {
        lifecycle.confirmAccountSwitchMerge()
    }

    public func noteLocalChanges(_ mutations: HistoryMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.filter(includes).map(\.recordName))
    }

    private func makeLifecycle() -> CloudSyncLifecycle {
        let journal = journal
        let context = context
        let kind = kind
        return CloudSyncLifecycle(
            store: CloudSyncLifecycleStore(
                state: {
                    let state = try journal.state()
                    return CloudSyncState(
                        engineStateData: state.engineStateData, boundUserRecordName: state.boundUserRecordName,
                        pendingUserRecordName: state.pendingUserRecordName, lastSuccessfulSync: state.lastSuccessfulSync
                    )
                },
                updateState: { value in
                    let state = try journal.state()
                    state.engineStateData = value.engineStateData
                    state.boundUserRecordName = value.boundUserRecordName
                    state.pendingUserRecordName = value.pendingUserRecordName
                    state.lastSuccessfulSync = value.lastSuccessfulSync
                },
                save: { try context.save() }, rollback: { context.rollback() },
                pendingChanges: {
                    try CloudSyncRecordStateStore(context: context, scope: $0).pendingChanges(journal.cloudRecords())
                },
                safety: .persistentHistory(context: context, kind: kind),
                resetForNewAccount: { try journal.resetForNewAccount() },
                resetForZone: { try journal.resetForZone() },
                resetForEnvironment: { try journal.resetForZone() },
                replica: .persistent(context: context, records: journal.cloudRecords)),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: Self.containerIdentifier, defaults: defaults,
            enabledKey: kind == .connectionHistory ? SettingsKey.historySyncEnabled : nil,
            defaultEnabled: SettingsKey.defaultHistorySyncEnabled,
            environmentKey: kind == .connectionHistory
                ? SettingsKey.historySyncEnvironment : SettingsKey.deviceSyncEnvironment,
            environmentIdentifier: environmentIdentifier,
            consumerIdentifier: kind == .device ? "device" : "",
            receiveSnapshot: { [weak self] in try self?.receiveRemoteRecords($0, deletions: $1) })
    }

    public nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)]))
    }

    public nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await lifecycle.handle(
            CloudSyncEventInput(event), engine: syncEngine,
            receiveRemoteRecords: { try receiveRemoteRecords($0, deletions: $1) },
            handleSentChanges: handleSentChanges)
    }

    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeChangeBatch(context, engine: syncEngine)
    }

    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        makeChangeBatch(
            engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }, engine: engine)
    }

    func makeChangeBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], engine: any CloudSyncEngineSession
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        let excluded = Set(
            pending.compactMap { change -> String? in
                guard case .saveRecord(let id) = change, let key = HistoryRecordKey(recordName: id.recordName),
                    !includes(key)
                else { return nil }
                return id.recordName
            })
        engine.removePending(excluded, in: zoneID)
        return lifecycle.makeChangeBatch(pending, engine: engine) { recordToSave($0, engine: engine) }
    }

    func recordToSave(_ recordID: CKRecord.ID, engine: any CloudSyncEngineSession) -> CKRecord? {
        do {
            guard try lifecycle.canUpload(recordID, engine: engine), let scope = lifecycle.scope,
                let key = HistoryRecordKey(recordName: recordID.recordName), includes(key),
                let outgoing = try journal.outgoingEntry(for: key, scope: scope)
            else { return nil }
            return try Self.makeRecord(outgoing, recordID: recordID)
        } catch {
            lifecycle.failClosed(error)
            return nil
        }
    }

    func receiveRemoteRecords(
        _ records: [CKRecord], deletions: [CKRecord.ID] = [], isConflict: Bool = false
    ) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        lifecycle.noteRecordsObserved(records)
        let deletedKeys = Set(
            deletions.compactMap { id -> HistoryRecordKey? in
                guard id.zoneID == zoneID, let key = HistoryRecordKey(recordName: id.recordName), includes(key)
                else { return nil }
                return key
            })
        let deletedNames = Set(deletedKeys.map(\.recordName))
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let decoded: [(record: CKRecord, envelope: HistoryEnvelope)] = try decodeCloudSyncRecords(
            records.filter { !deletedNames.contains($0.recordID.recordName) },
            included: { record in
                guard record.recordID.zoneID == zoneID,
                    isConflict || record.recordType == kind.recordType
                else { return false }
                return HistoryRecordKey(recordName: record.recordID.recordName).map(includes) != false
            },
            decode: Self.envelope,
            quarantine: {
                try CloudSyncRecordCoding.quarantine($0, error: $1, in: safety, nativeFields: true)
            },
            logFailure: { lifecycle.logFailure($0, stage: "decode-quarantine") })
        let changed = try persistence.applyRemote(
            decoded.map { $0.1 }, deletions: deletedKeys,
            beforeSave: {
                for (record, envelope) in decoded {
                    try cloud.observed(record.recordID.recordName)
                    try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
                    if try journal.envelope(for: envelope.key) == envelope {
                        try journal.markUploaded(envelope.key, version: envelope.version)
                    }
                    try safety.clearQuarantine(recordName: record.recordID.recordName)
                }
                for key in deletedKeys {
                    guard let envelope = try journal.envelope(for: key), envelope.isDeleted else { continue }
                    try journal.acknowledgeDeletion(
                        .init(recordName: key.recordName, operation: .delete, version: envelope.version), scope: scope)
                }
            })
        try lifecycle.reconcilePendingChanges()
        if !changed.isEmpty { didApplyRemote?(changed) }
    }

    func handleSentChanges(_ changes: CloudSyncSentChanges) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        for record in changes.savedRecords
        where record.recordID.zoneID == zoneID
            && HistoryRecordKey(recordName: record.recordID.recordName).map(includes) == true
        {
            guard try !lifecycle.store.safety.isUploadBlocked(scope, record.recordID.recordName) else { continue }
            let envelope = try Self.envelope(from: record)
            try cloud.observed(record.recordID.recordName)
            if try journal.envelope(for: envelope.key)?.isDeleted == true {
                // An in-flight save may finish after a local/remote deletion. Delete its server copy again.
                try journal.markNeedsUpload([envelope.key])
            } else {
                try journal.markUploaded(envelope.key, version: envelope.version)
                try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
            }
        }
        for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
            if failure.error.code == .unknownItem,
                try cloud.wasPresent(failure.record.recordID.recordName)
            {
                try receiveRemoteRecords([], deletions: [failure.record.recordID])
            } else {
                try handleFailedSave(failure.error)
            }
        }
        try lifecycle.handleDeletedRecords(changes) { mutation in
            try journal.acknowledgeDeletion(mutation, scope: scope)
            try cloud.acknowledgeLegacyDeletion(mutation)
        }
        try context.save()
        try lifecycle.reconcilePendingChanges()
    }

    func handleFailedSave(_ error: CKError) throws {
        try lifecycle.handleFailedSave(error) {
            try receiveRemoteRecords($0, isConflict: $1)
        }
    }

    public nonisolated static func makeRecord(
        _ outgoing: HistoryOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record = try CloudSyncRecordCoding.makeRecord(
            type: envelope.key.kind.recordType, id: recordID, systemFields: outgoing.systemFieldsData)
        try HistoryCloudRecordV1.write(envelope, into: record)
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> HistoryEnvelope {
        try HistoryCloudRecordV1.read(record)
    }

    public nonisolated static func systemFields(of record: CKRecord) throws -> Data {
        try CloudSyncRecordCoding.systemFields(of: record)
    }
}

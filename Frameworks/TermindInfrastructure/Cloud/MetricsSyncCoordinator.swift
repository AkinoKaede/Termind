import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

/// Metrics use their own private zone so their default-on category can be paused
/// independently from Vault and Settings.
@MainActor
@Observable
public final class MetricsSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public nonisolated static let zoneName = "TermindMetricsV1"
    public nonisolated static let recordType = "MetricsItem"
    public nonisolated static let subscriptionID = "termind-metrics-v1-changes"
    nonisolated static let assetDirectoryName = "Termind/MetricsSyncAssets"

    private let context: ModelContext
    private let persistence: MetricsSyncPersistence
    private let journal: MetricsSyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let assetCacheRoot: URL?
    private let removeAssetDirectory: (URL) throws -> Void
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    public var status: VaultSyncStatus { lifecycle.status }
    public var didApplyRemote: ((MetricsSyncSnapshot, Set<MetricsRecordKey>) -> Void)?

    public convenience init(
        persistence: MetricsSyncPersistence,
        container: CKContainer = CKContainer(identifier: CloudSyncContainer.identifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = CloudSyncContainer.environmentIdentifier
    ) {
        self.init(
            persistence: persistence, defaults: defaults, environmentIdentifier: environmentIdentifier,
            makeTransport: {
                .live(container: container, zoneID: $0, subscriptionID: Self.subscriptionID, delegate: $1)
            })
    }

    init(
        persistence: MetricsSyncPersistence,
        defaults: UserDefaults, environmentIdentifier: String,
        assetCacheRoot: URL? = nil,
        removeAssetDirectory: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        journal = persistence.journal
        self.makeTransport = makeTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        self.assetCacheRoot = assetCacheRoot
        self.removeAssetDirectory = removeAssetDirectory
        super.init()
        persistence.didRecordChanges = { [weak self] mutations in self?.noteLocalChanges(mutations) }
    }

    public func configureLogging(_ logging: any ApplicationLogManaging) {
        lifecycle.logger = logging.makeLogger(label: "termind.cloud-sync")
    }

    public func start() { lifecycle.start() }
    public func setEnabled(_ enabled: Bool) { lifecycle.setEnabled(enabled) }
    public func pause() { lifecycle.pause() }
    public func retry() { lifecycle.retry() }
    public func confirmAccountSwitchMerge() { lifecycle.confirmAccountSwitchMerge() }

    public func noteLocalChanges(_ mutations: MetricsMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.map(\.recordName))
    }

    private func makeLifecycle() -> CloudSyncLifecycle {
        let journal = journal
        let context = context
        return CloudSyncLifecycle(
            store: CloudSyncLifecycleStore(
                state: journal.syncState, updateState: journal.updateSyncState,
                save: { try context.save() }, rollback: { context.rollback() },
                pendingChanges: {
                    try CloudSyncRecordStateStore(context: context, scope: $0).pendingChanges(journal.cloudRecords())
                },
                safety: .persistent(context: context, capabilityID: MetricsSyncCodec.capabilityID),
                resetForNewAccount: { try journal.markAllLiveRecordsNeedsUploadForNewAccount() },
                resetForZone: { try journal.markAllEntriesNeedsUploadAfterZoneReset() },
                resetForEnvironment: { try journal.markAllEntriesNeedsUploadAfterEnvironmentChange() },
                purge: { [weak self] scope in
                    guard let self else { throw CancellationError() }
                    let result = try self.persistence.purgeCloudCache(
                        scope: scope, assetCleanupKey: Self.assetDirectoryName)
                    self.didApplyRemote?(result.0, result.1)
                    try self.completePendingAssetPurge()
                },
                completePendingPurge: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try self.completePendingAssetPurge()
                },
                replica: .persistent(
                    context: context, records: journal.cloudRecords,
                    clearSystemFields: journal.clearSystemFields,
                    handlesRecordName: { MetricsRecordKey(recordName: $0) != nil })),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: CloudSyncContainer.identifier, defaults: defaults,
            enabledKey: SettingsKey.metricsSyncEnabled, defaultEnabled: SettingsKey.defaultMetricsSyncEnabled,
            environmentKey: SettingsKey.metricsSyncEnvironment, environmentIdentifier: environmentIdentifier,
            receiveSnapshot: { [weak self] in try self?.receiveRemoteRecords($0, deletions: $1) })
    }

    private func completePendingAssetPurge() throws {
        try CloudSyncRecordCoding.completePendingAssetPurge(
            directoryName: Self.assetDirectoryName, context: context, cacheRoot: assetCacheRoot,
            removeItem: removeAssetDirectory)
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
        lifecycle.makeChangeBatch(pending, engine: engine) { recordToSave($0, engine: engine) }
    }

    func recordToSave(_ recordID: CKRecord.ID, engine: any CloudSyncEngineSession) -> CKRecord? {
        do {
            guard try lifecycle.canUpload(recordID, engine: engine), let scope = lifecycle.scope,
                let key = MetricsRecordKey(recordName: recordID.recordName),
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
        let reconciled = try lifecycle.reconcileRemoteChanges(records: records, deletions: deletions)
        let (records, deletions) = (reconciled.records, reconciled.deletions)
        lifecycle.noteRecordsObserved(records, excluding: deletions)
        let deletedKeys = Set(
            deletions.compactMap { id -> MetricsRecordKey? in
                guard id.zoneID == zoneID, let key = MetricsRecordKey(recordName: id.recordName)
                else { return nil }
                return key
            })
        let deletedNames = Set(deletedKeys.map(\.recordName))
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let decoded: [(record: CKRecord, envelope: MetricsEnvelope)] = try decodeCloudSyncRecords(
            records.filter { !deletedNames.contains($0.recordID.recordName) },
            included: { $0.recordID.zoneID == zoneID && (isConflict || $0.recordType == Self.recordType) },
            decode: Self.envelope,
            quarantine: { try CloudSyncRecordCoding.quarantine($0, error: $1, in: safety) },
            logFailure: { lifecycle.logFailure($0, stage: "decode-quarantine") })
        let result = try persistence.applyRemote(
            decoded.map { $0.1 }, deletions: deletedKeys,
            beforeSave: {
                for (record, envelope) in decoded {
                    try journal.noteRemoteRecord(record, envelope: envelope, cloud: cloud, safety: safety)
                }
                try journal.acknowledgeRemoteDeletions(deletedKeys, scope: scope)
            })
        try lifecycle.reconcilePendingChanges()
        if !result.acceptedKeys.isEmpty { didApplyRemote?(result.snapshot, result.acceptedKeys) }
    }

    func handleSentChanges(_ changes: CloudSyncSentChanges) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        for record in changes.savedRecords where record.recordID.zoneID == zoneID {
            guard try !safety.isUploadBlocked(recordName: record.recordID.recordName) else { continue }
            let envelope = try Self.envelope(from: record)
            try journal.acknowledgeSavedRecord(record, envelope: envelope, cloud: cloud)
            try? FileManager.default.removeItem(at: Self.assetURL(for: envelope.key))
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
        _ outgoing: MetricsOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record = try CloudSyncRecordCoding.makeRecord(
            type: recordType, id: recordID, systemFields: outgoing.systemFieldsData)
        let payload = try MetricsSyncCodec.encode(envelope)
        CloudSyncRecordCoding.setMetadata(
            on: record, formatVersion: envelope.formatVersion, kind: envelope.key.kind.rawValue,
            entityID: envelope.key.id.uuidString.lowercased(), version: envelope.version,
            isDeleted: envelope.isDeleted)
        try CloudSyncRecordCoding.setPayload(payload, on: record, assetURL: assetURL(for: envelope.key))
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> MetricsEnvelope {
        let data = try CloudSyncRecordCoding.validatedPayloadData(
            from: record, invalidEnvelope: MetricsSyncPersistenceError.invalidEnvelope(record.recordID.recordName))
        let envelope = try MetricsSyncCodec.decode(data)
        guard record.recordType == recordType, envelope.key.recordName == record.recordID.recordName, envelope.isValid
        else {
            throw MetricsSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return envelope
    }

    private nonisolated static func assetURL(for key: MetricsRecordKey) throws -> URL {
        try CloudSyncRecordCoding.assetURL(recordName: key.recordName, directoryName: assetDirectoryName)
    }
}

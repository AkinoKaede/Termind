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
    public nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    public nonisolated static let zoneName = "TermindMetricsV1"
    public nonisolated static let recordType = "MetricsItem"
    public nonisolated static let subscriptionID = "termind-metrics-v1-changes"
    public nonisolated static let inlinePayloadLimit = CloudSyncRecordCoding.inlinePayloadLimit

    private let context: ModelContext
    private let persistence: MetricsSyncPersistence
    private let journal: MetricsSyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    public private(set) var status: VaultSyncStatus {
        get { lifecycle.status }
        set { lifecycle.status = newValue }
    }
    public var didApplyRemote: ((MetricsSyncSnapshot, Set<MetricsRecordKey>) -> Void)?

    public var isEnabled: Bool { lifecycle.isEnabled }

    public convenience init(
        persistence: MetricsSyncPersistence,
        container: CKContainer = CKContainer(identifier: MetricsSyncCoordinator.containerIdentifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = MetricsSyncCoordinator.runtimeEnvironmentIdentifier
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
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        journal = persistence.journal
        self.makeTransport = makeTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()
        persistence.didRecordChanges = { [weak self] mutations in self?.noteLocalChanges(mutations) }
    }

    public nonisolated static var runtimeEnvironmentIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindCloudKitEnvironment") as? String ?? "Unknown"
    }

    public func start() { lifecycle.start() }
    public func setEnabled(_ enabled: Bool) { lifecycle.setEnabled(enabled) }
    public func pause() { lifecycle.pause() }
    public func retry() { lifecycle.retry() }
    public func confirmAccountSwitchMerge() { lifecycle.confirmAccountSwitchMerge() }

    public func noteLocalChanges(_ mutations: MetricsMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.map(\.recordName))
    }

    private func addPendingChanges(_ keys: Set<MetricsRecordKey>) {
        lifecycle.enqueue(keys.map(\.recordName))
    }

    private func makeLifecycle() -> CloudSyncLifecycle {
        let journal = journal
        let context = context
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
                pendingRecordNames: { try journal.pendingEnvelopes().map(\.key.recordName) },
                quarantineReason: { try journal.firstQuarantineReason() },
                resetForNewAccount: { try journal.markAllLiveRecordsNeedsUploadForNewAccount() },
                resetForZone: { try journal.markAllEntriesNeedsUploadAfterZoneReset() },
                resetForEnvironment: { try journal.markAllEntriesNeedsUploadAfterEnvironmentChange() }),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, defaults: defaults,
            enabledKey: SettingsKey.metricsSyncEnabled, defaultEnabled: SettingsKey.defaultMetricsSyncEnabled,
            environmentKey: SettingsKey.metricsSyncEnvironment, environmentIdentifier: environmentIdentifier,
            signInMessage: { String(localized: "Sign in to iCloud to sync Metrics.") })
    }

    public nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)]))
    }

    public nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, engine: syncEngine)
    }

    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeChangeBatch(context, engine: syncEngine)
    }

    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard lifecycle.accepts(engine), lifecycle.isReadyToSend else { return nil }
        let pending = engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { [weak self] recordID in
            guard let self else { return nil }
            return await self.recordToSave(recordID)
        }
    }

    private func recordToSave(_ recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == zoneID, let key = MetricsRecordKey(recordName: recordID.recordName),
            let outgoing = try? journal.outgoingEntry(for: key)
        else { return nil }
        do { return try Self.makeRecord(outgoing, recordID: recordID) } catch {
            lifecycle.terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard lifecycle.accepts(engine) else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try lifecycle.saveEngineState(update.stateSerialization)
            case .accountChange(let change):
                try lifecycle.handleAccountChange(change.changeType)
            case .fetchedRecordZoneChanges(let changes):
                try handleFetchedChanges(changes, engine: engine)
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    try lifecycle.handleZoneDeletion()
                }
            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes, engine: engine)
            case .didFetchChanges, .didSendChanges:
                try lifecycle.updateUpToDateStatus()
            default:
                break
            }
        } catch {
            context.rollback()
            status = lifecycle.status(for: error)
        }
    }

    private func handleFetchedChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine
    ) throws {
        var recordsByKey: [MetricsRecordKey: CKRecord] = [:]
        var envelopes: [MetricsEnvelope] = []
        var quarantinedError: String?
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordType == Self.recordType, record.recordID.zoneID == zoneID else { continue }
            do {
                let envelope = try Self.envelope(from: record)
                try journal.clearQuarantine(recordName: record.recordID.recordName)
                recordsByKey[envelope.key] = record
                envelopes.append(envelope)
            } catch {
                try journal.quarantine(
                    recordName: record.recordID.recordName,
                    payloadData: (try? Self.payloadData(from: record)) ?? Data(),
                    reason: error.localizedDescription)
                quarantinedError = error.localizedDescription
            }
        }

        let result = try persistence.applyRemote(envelopes)
        for (key, record) in recordsByKey {
            try journal.updateSystemFields(Self.systemFields(of: record), for: key)
        }
        try journal.markNeedsUpload(result.needsUpload)
        let physicallyDeleted = Set(
            changes.deletions.compactMap {
                $0.recordID.zoneID == zoneID ? MetricsRecordKey(recordName: $0.recordID.recordName) : nil
            }
        ).filter { (try? journal.envelope(for: $0)) != nil }
        try journal.markNeedsUpload(physicallyDeleted)
        addPendingChanges(result.needsUpload.union(physicallyDeleted))
        try context.save()
        if !result.acceptedKeys.isEmpty { didApplyRemote?(result.snapshot, result.acceptedKeys) }
        if let quarantinedError { status = .failed(quarantinedError) }
    }

    private func handleSentChanges(
        _ changes: CKSyncEngine.Event.SentRecordZoneChanges, engine: CKSyncEngine
    ) throws {
        for record in changes.savedRecords where record.recordID.zoneID == zoneID {
            guard let envelope = try? Self.envelope(from: record) else { continue }
            try journal.markUploaded(envelope.key, version: envelope.version)
            try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
            try? FileManager.default.removeItem(at: Self.assetURL(for: envelope.key))
        }
        for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
            let error = failure.error
            if error.code == .serverRecordChanged, let serverRecord = error.serverRecord,
                let serverEnvelope = try? Self.envelope(from: serverRecord)
            {
                let localEnvelope = try journal.envelope(for: serverEnvelope.key)
                let result = try persistence.applyRemote([serverEnvelope])
                try journal.updateSystemFields(Self.systemFields(of: serverRecord), for: serverEnvelope.key)
                if localEnvelope == serverEnvelope {
                    try journal.markUploaded(serverEnvelope.key, version: serverEnvelope.version)
                } else {
                    try journal.markNeedsUpload(result.needsUpload)
                    addPendingChanges(result.needsUpload)
                }
                if !result.acceptedKeys.isEmpty { didApplyRemote?(result.snapshot, result.acceptedKeys) }
            } else if error.code == .zoneNotFound {
                try lifecycle.handleZoneDeletion()
            } else if !CloudSyncLifecycle.isRetryable(error) {
                lifecycle.terminalError = error.localizedDescription
                status = .failed(error.localizedDescription)
            }
        }
        try context.save()
    }

    public nonisolated static func makeRecord(
        _ outgoing: MetricsOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record = try CloudSyncRecordCoding.makeRecord(
            type: recordType, id: recordID, systemFields: outgoing.systemFieldsData)
        let payload = try MetricsSyncCodec.encode(envelope)
        record["formatVersion"] = NSNumber(value: envelope.formatVersion)
        record["kind"] = envelope.key.kind.rawValue as NSString
        record["entityID"] = envelope.key.id.uuidString.lowercased() as NSString
        record["modifiedAt"] = envelope.version.modifiedAt as NSDate
        record["counter"] = NSNumber(value: Int64(clamping: envelope.version.counter))
        record["writerID"] = envelope.version.writerID.uuidString.lowercased() as NSString
        record["isDeleted"] = NSNumber(value: envelope.isDeleted)
        try CloudSyncRecordCoding.setPayload(payload, on: record, assetURL: assetURL(for: envelope.key))
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> MetricsEnvelope {
        let data = try CloudSyncRecordCoding.validatedPayloadData(
            from: record, invalidEnvelope: MetricsSyncPersistenceError.invalidEnvelope(record.recordID.recordName))
        let envelope = try MetricsSyncCodec.decode(data)
        guard envelope.key.recordName == record.recordID.recordName, envelope.isValid else {
            throw MetricsSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return envelope
    }

    public nonisolated static func payloadData(from record: CKRecord) throws -> Data {
        try CloudSyncRecordCoding.payloadData(
            from: record, invalidEnvelope: MetricsSyncPersistenceError.invalidEnvelope(record.recordID.recordName))
    }

    public nonisolated static func systemFields(of record: CKRecord) throws -> Data {
        try CloudSyncRecordCoding.systemFields(of: record)
    }

    private nonisolated static func assetURL(for key: MetricsRecordKey) throws -> URL {
        try CloudSyncRecordCoding.assetURL(recordName: key.recordName, directoryName: "Termind/MetricsSyncAssets")
    }

}

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

/// Two kinds share a transport but NOT an opt-in policy: devices follow the master
/// iCloud switch, while events additionally require History selection. Neither
/// depends on Vault selection. Every read, restored queue and final writer checks
/// the kind policy; re-enabling History replays both zones through capability IDs.
@MainActor
@Observable
public final class HistorySyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    public nonisolated static let zoneName = "TermindConnectionHistoryV1"
    public nonisolated static let recordTypes = Set(HistoryRecordKind.allCases.map(\.recordType))
    public nonisolated static let subscriptionID = "termind-connection-history-v1-changes"

    private let context: ModelContext
    private let persistence: HistorySyncPersistence
    private let journal: HistorySyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let makeLegacyTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    @ObservationIgnored private(set) lazy var legacyImporter = makeLegacyImporter()
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
    public var isHistoryEnabled: Bool { isEnabled && includesHistory }
    private var includesHistory: Bool {
        defaults.object(forKey: SettingsKey.historySyncEnabled) as? Bool ?? SettingsKey.defaultHistorySyncEnabled
    }
    private func includes(_ key: HistoryRecordKey) -> Bool { key.kind == .device || includesHistory }
    public var historyStatus: VaultSyncStatus { includesHistory ? status(for: .connectionHistory) : .paused }
    public var deviceStatus: VaultSyncStatus { status(for: .device) }

    public convenience init(
        persistence: HistorySyncPersistence,
        container: CKContainer = CKContainer(identifier: HistorySyncCoordinator.containerIdentifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = HistorySyncCoordinator.runtimeEnvironmentIdentifier
    ) {
        self.init(
            persistence: persistence, defaults: defaults, environmentIdentifier: environmentIdentifier,
            makeTransport: {
                .live(container: container, zoneID: $0, subscriptionID: Self.subscriptionID, delegate: $1)
            },
            makeLegacyTransport: {
                .live(
                    container: container, zoneID: $0, subscriptionID: LegacyHistoryImporter.subscriptionID,
                    delegate: $1, readOnly: true)
            })
    }

    init(
        persistence: HistorySyncPersistence,
        defaults: UserDefaults, environmentIdentifier: String,
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport,
        makeLegacyTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        journal = persistence.journal
        self.makeTransport = makeTransport
        self.makeLegacyTransport = makeLegacyTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()

    }

    public nonisolated static var runtimeEnvironmentIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindCloudKitEnvironment") as? String ?? "Unknown"
    }

    public func configureLogging(_ logging: any ApplicationLogManaging) {
        lifecycle.logger = logging.makeLogger(label: "termind.cloud-sync")
    }

    public func start() {
        if !isEnabled { legacyImporter.stop() }
        lifecycle.start()
    }
    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.historySyncEnabled)
        // Retire in-flight callbacks so an off switch cannot import a late event.
        // Device sync restarts immediately; capability changes replay skipped events on opt-in.
        legacyImporter.stop()
        lifecycle.pause()
        lifecycle.start()
    }
    public func pause() {
        legacyImporter.stop()
        lifecycle.pause()
    }
    public func retry() {
        // Recreate both readers after an import failure, preserving their persisted replay fences.
        legacyImporter.stop()
        lifecycle.pause()
        lifecycle.retry()
    }
    public func confirmAccountSwitchMerge() {
        legacyImporter.stop()
        lifecycle.confirmAccountSwitchMerge()
    }

    public func noteLocalChanges(_ mutations: HistoryMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.map(\.recordName))
    }

    private func makeLegacyImporter() -> LegacyHistoryImporter {
        let defaults = defaults
        let importer = LegacyHistoryImporter(
            context: context,
            includesHistory: {
                defaults.object(forKey: SettingsKey.historySyncEnabled) as? Bool
                    ?? SettingsKey.defaultHistorySyncEnabled
            }, makeTransport: makeLegacyTransport)
        importer.didApply = { [weak self] keys in self?.didApplyRemote?(keys) }
        importer.didFinish = { [weak self, weak importer] in
            guard let self, let importer, let scope = lifecycle.scope, importer.ready(for: scope) else { return }
            do {
                lifecycle.noteLocalChanges(try journal.uploadablePendingRecordNames(in: scope))
                // The source may have gained or cleared a quarantine without
                // producing any destination mutations. Recompute the visible
                // status after its checkpoint commits, even with no uploads.
                try lifecycle.updateUpToDateStatus()
            } catch {
                lifecycle.failClosed(error)
            }
        }
        importer.logFailure = { [weak self] error in self?.lifecycle.logFailure(error, stage: "legacy-import") }
        importer.didChangeAccount = { [weak self] change in
            guard let self else { return }
            do { try lifecycle.handleAccountChange(change) } catch { lifecycle.failClosed(error) }
        }
        importer.didFail = { [weak self] error in self?.lifecycle.failClosed(error) }
        return importer
    }

    private func makeLifecycle() -> CloudSyncLifecycle {
        let journal = journal
        let context = context
        let defaults = defaults
        let includesHistory = {
            defaults.object(forKey: SettingsKey.historySyncEnabled) as? Bool ?? SettingsKey.defaultHistorySyncEnabled
        }
        let lifecycle = CloudSyncLifecycle(
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
                pendingRecordNames: { scope in
                    try journal.uploadablePendingRecordNames(in: scope).filter {
                        includesHistory() || HistoryRecordKey(recordName: $0)?.kind != .connectionHistory
                    }
                },
                safety: .persistentHistory(
                    context: context, includesHistory: includesHistory,
                    importLegacyQuarantine: journal.importLegacyQuarantine),
                resetForNewAccount: { try journal.resetForNewAccount() },
                resetForZone: { try journal.resetForZone() },
                resetForEnvironment: { try journal.resetForZone() }),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: Self.containerIdentifier, defaults: defaults,
            enabledKey: nil, defaultEnabled: SettingsKey.defaultHistorySyncEnabled,
            environmentKey: SettingsKey.historySyncEnvironment, environmentIdentifier: environmentIdentifier,
            signInMessage: { String(localized: "Sign in to iCloud to sync history.") },
            prepareUploads: { [weak self] scope in
                guard let self else { throw CancellationError() }
                try await legacyImporter.prepare(destinationScope: scope)
            })
        lifecycle.didRetire = { [weak self] in self?.legacyImporter.stop() }
        return lifecycle
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
        makeChangeBatch(
            engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }, engine: engine)
    }

    func makeChangeBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], engine: any CloudSyncEngineSession
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let scope = lifecycle.scope, legacyImporter.ready(for: scope) else { return nil }
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
                legacyImporter.ready(for: scope),
                let key = HistoryRecordKey(recordName: recordID.recordName), includes(key),
                let outgoing = try journal.outgoingEntry(for: key, scope: scope)
            else { return nil }
            return try Self.makeRecord(outgoing, recordID: recordID)
        } catch {
            lifecycle.failClosed(error)
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
                try receiveRemoteRecords(
                    changes.modifications.map(\.record), deletions: changes.deletions.map(\.recordID))
            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    try lifecycle.handleZoneDeletion()
                }
            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes)
            case .willFetchChanges:
                try lifecycle.beginFetch()
            case .willSendChanges:
                try lifecycle.beginSend()
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error {
                    guard CloudSyncLifecycle.isRetryable(error) else { throw error }
                    lifecycle.noteFetchFailure(error)
                }
            case .didFetchChanges:
                try lifecycle.finishFetch()
                try lifecycle.updateUpToDateStatus()
            case .didSendChanges:
                try lifecycle.finishSend()
                try lifecycle.updateUpToDateStatus()
            default:
                break
            }
        } catch { lifecycle.failClosed(error) }
    }

    func receiveRemoteRecords(
        _ records: [CKRecord], deletions: [CKRecord.ID] = [], isConflict: Bool = false
    ) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        var decoded: [(CKRecord, HistoryEnvelope)] = []
        var rejected = Set<String>()
        for record in records
        where record.recordID.zoneID == zoneID && (isConflict || Self.recordTypes.contains(record.recordType)) {
            if let key = HistoryRecordKey(recordName: record.recordID.recordName), !includes(key) { continue }
            do {
                decoded.append((record, try Self.envelope(from: record)))
            } catch {
                lifecycle.logFailure(error, stage: "decode-quarantine")
                try CloudSyncRecordCoding.quarantine(record, error: error, in: safety, nativeFields: true)
                rejected.insert(record.recordID.recordName)
            }
        }
        decoded.removeAll { rejected.contains($0.0.recordID.recordName) }
        let identical = try Set(
            decoded.compactMap { _, envelope -> HistoryRecordKey? in
                guard isConflict else { return nil }
                return try journal.envelope(for: envelope.key) == envelope ? envelope.key : nil
            })
        let changed = try persistence.applyRemote(
            decoded.map { $0.1 },
            beforeSave: {
                for (record, envelope) in decoded {
                    try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
                    if identical.contains(envelope.key),
                        try !CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).isUploadBlocked(
                            recordName: envelope.key.recordName)
                    {
                        try journal.markUploaded(envelope.key, version: envelope.version)
                    }
                    try safety.clearQuarantine(recordName: record.recordID.recordName)
                }
                for id in deletions where id.zoneID == zoneID {
                    guard let key = HistoryRecordKey(recordName: id.recordName), includes(key),
                        try journal.envelope(for: key) != nil
                    else {
                        continue
                    }
                    try journal.markNeedsUpload([key])
                    if try !safety.isUploadBlocked(recordName: id.recordName) {
                        try journal.updateSystemFields(nil, for: key)
                    }
                }
            })
        try lifecycle.reconcilePendingChanges()
        if !changed.isEmpty { didApplyRemote?(changed) }
    }

    private func handleSentChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        for record in changes.savedRecords where record.recordID.zoneID == zoneID {
            guard try !lifecycle.store.safety.isUploadBlocked(scope, record.recordID.recordName) else { continue }
            let envelope = try Self.envelope(from: record)
            try journal.markUploaded(envelope.key, version: envelope.version)
            try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
        }
        for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
            try handleFailedSave(failure.error)
        }
        try context.save()
    }

    func handleFailedSave(_ error: CKError) throws {
        if error.code == .serverRecordChanged {
            guard let serverRecord = error.serverRecord else { throw error }
            try receiveRemoteRecords([serverRecord], isConflict: true)
        } else if error.code == .zoneNotFound {
            try lifecycle.handleZoneDeletion()
        } else if !CloudSyncLifecycle.isRetryable(error) {
            lifecycle.logFailure(error, stage: "save")
            lifecycle.terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
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

extension HistorySyncCoordinator {
    private func status(for kind: HistoryRecordKind) -> VaultSyncStatus {
        guard let scope = lifecycle.scope else { return lifecycle.status }
        if case .upToDate = lifecycle.status, !legacyImporter.ready(for: scope) { return .syncing(pendingCount: 0) }
        switch lifecycle.status {
        case .syncing, .partiallyBlocked:
            do {
                let pending = try journal.uploadablePendingRecordNames(in: scope).filter {
                    HistoryRecordKey(recordName: $0)?.kind == kind
                }.count
                var blocked = Set<String>()
                var requiresUpdate = false
                for replica in [scope, scope.historyImportScope] {
                    let safety = CloudSyncSafetyStore(context: context, scope: replica)
                    for name in try safety.blockedRecordNames() {
                        let recordKind = HistoryRecordKey(recordName: name)?.kind
                        // Unknown kinds belong to the always-selected portion so an
                        // optional History toggle cannot hide an upgrade requirement.
                        guard recordKind == kind || (recordKind == nil && kind == .device) else { continue }
                        blocked.insert(name)
                        if try safety.entry(recordName: name)?.reasonCode
                            == CloudSyncQuarantineReason.unsupportedFormat.rawValue
                        {
                            requiresUpdate = true
                        }
                    }
                }
                if !blocked.isEmpty {
                    return .partiallyBlocked(
                        pendingCount: pending, blockedCount: blocked.count, requiresUpdate: requiresUpdate)
                }
                if case .partiallyBlocked = lifecycle.status, pending == 0 {
                    return .upToDate(lastSuccessfulSync: try journal.state().lastSuccessfulSync)
                }
                return .syncing(pendingCount: pending)
            } catch { return .failed(error.localizedDescription) }
        default: return lifecycle.status
        }
    }
}

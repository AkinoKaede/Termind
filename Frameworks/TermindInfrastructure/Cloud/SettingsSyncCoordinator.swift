import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

/// Settings use their own zone, account binding, and upload queue.
@MainActor
@Observable
public final class SettingsSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    // Keep the initial AI-sync identifiers so existing replicas remain reachable.
    public nonisolated static let zoneName = "TermindAIConfigurationV1"
    public nonisolated static let recordType = "AIConfigurationItem"
    // Older clients filter by record type before decoding, so they can ignore newer preferences safely.
    public nonisolated static let sshRecordType = "SSHPreferencesItem"
    public nonisolated static let sftpRecordType = "SFTPPreferencesItem"
    public nonisolated static let subscriptionID = "termind-ai-configuration-v1-changes"
    public nonisolated static let inlinePayloadLimit = CloudSyncRecordCoding.inlinePayloadLimit

    private let context: ModelContext
    private let persistence: SettingsSyncPersistence
    private let secrets: AISecretStore
    private let journal: SettingsSyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    public private(set) var status: VaultSyncStatus {
        get { lifecycle.status }
        set { lifecycle.status = newValue }
    }
    public var didApplyRemote: ((SettingsSyncSnapshot, Set<SettingsRecordKey>) -> Void)?

    public var isEnabled: Bool { lifecycle.isEnabled }

    public convenience init(
        persistence: SettingsSyncPersistence,
        secrets: AISecretStore,
        container: CKContainer = CKContainer(identifier: SettingsSyncCoordinator.containerIdentifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = SettingsSyncCoordinator.runtimeEnvironmentIdentifier
    ) {
        self.init(
            persistence: persistence, secrets: secrets, defaults: defaults,
            environmentIdentifier: environmentIdentifier,
            makeTransport: {
                .live(container: container, zoneID: $0, subscriptionID: Self.subscriptionID, delegate: $1)
            })
    }

    init(
        persistence: SettingsSyncPersistence,
        secrets: AISecretStore,
        defaults: UserDefaults, environmentIdentifier: String,
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        self.secrets = secrets
        journal = persistence.journal
        self.makeTransport = makeTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()
        persistence.didRecordChanges = { [weak self] mutations in self?.noteLocalChanges(mutations) }
    }

    public nonisolated static var runtimeEnvironmentIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindCloudKitEnvironment") as? String
            ?? "Unknown"
    }

    public func start() { lifecycle.start() }
    public func setEnabled(_ enabled: Bool) { lifecycle.setEnabled(enabled) }
    public func pause() { lifecycle.pause() }
    public func retry() { lifecycle.retry() }
    public func confirmAccountSwitchMerge() { lifecycle.confirmAccountSwitchMerge() }

    public func noteLocalChanges(_ mutations: SettingsMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.filter { $0.kind.participatesInSync }.map(\.recordName))
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
                pendingRecordNames: { try journal.uploadablePendingRecordNames(in: $0) },
                safety: .persistent(context: context, importLegacyQuarantine: journal.importLegacyQuarantine),
                resetForNewAccount: { try journal.markAllLiveRecordsNeedsUploadForNewAccount() },
                resetForZone: { try journal.markAllEntriesNeedsUploadAfterZoneReset() },
                resetForEnvironment: { try journal.markAllEntriesNeedsUploadAfterEnvironmentChange() }),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: Self.containerIdentifier, defaults: defaults,
            enabledKey: SettingsKey.settingsSyncEnabled, defaultEnabled: SettingsKey.defaultSettingsSyncEnabled,
            environmentKey: SettingsKey.settingsSyncEnvironment, environmentIdentifier: environmentIdentifier,
            signInMessage: { String(localized: "Sign in to iCloud to sync settings.") },
            authorizeUploads: { [secrets] in secrets.uploadsAuthorized = $0 },
            beforeSend: { [weak self] in try self?.migrateSecrets() })
    }

    private func migrateSecrets() throws {
        let config = try persistence.load().configuration
        try secrets.migrate(
            Set(
                config.providers.flatMap { [$0.credentialRef, $0.vertex.credentialRef] }
                    + config.mcpServers.map(\.credentialRef)))
    }

    private func applyRemote(_ envelopes: [SettingsEnvelope], beforeSave: () throws -> Void) throws
        -> (
            snapshot: SettingsSyncSnapshot, acceptedKeys: Set<SettingsRecordKey>,
            needsUpload: Set<SettingsRecordKey>
        )
    {
        let result = try persistence.applyRemote(envelopes, beforeSave: beforeSave)
        let references = envelopes.filter { result.acceptedKeys.contains($0.key) }.flatMap { envelope -> [String] in
            switch envelope.payload {
            case .provider(let value): [value.credentialRef, value.vertex?.credentialRef ?? ""]
            case .mcpServer(let value): [value.credentialRef]
            default: []
            }
        }
        try secrets.acceptRemoteReferences(Set(references))
        return result
    }

    public nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)]))
    }

    public nonisolated func handleEvent(
        _ event: CKSyncEngine.Event, syncEngine: CKSyncEngine
    ) async {
        await handle(event, engine: syncEngine)
    }

    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeChangeBatch(context, engine: syncEngine)
    }

    @MainActor
    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        makeChangeBatch(
            engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }, engine: engine)
    }

    func makeChangeBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], engine: any CloudSyncEngineSession
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard lifecycle.accepts(engine), lifecycle.isReadyToSend else { return nil }
        do { try migrateSecrets() } catch {
            lifecycle.failClosed(error)
            return nil
        }
        return lifecycle.makeChangeBatch(pending, engine: engine) { recordToSave($0, engine: engine) }
    }

    func recordToSave(_ recordID: CKRecord.ID, engine: any CloudSyncEngineSession) -> CKRecord? {
        do {
            guard try lifecycle.canUpload(recordID, engine: engine), let scope = lifecycle.scope,
                let key = SettingsRecordKey(recordName: recordID.recordName),
                let outgoing = try journal.outgoingEntry(for: key, scope: scope)
            else { return nil }
            return try Self.makeRecord(outgoing, recordID: recordID)
        } catch {
            lifecycle.failClosed(error)
            return nil
        }
    }

    @MainActor
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
        var decoded: [(CKRecord, SettingsEnvelope)] = []
        var rejected = Set<String>()
        for record in records
        where record.recordID.zoneID == zoneID && (isConflict || Self.acceptsRecordType(record.recordType)) {
            if let key = SettingsRecordKey(recordName: record.recordID.recordName), !key.kind.participatesInSync {
                continue
            }
            do {
                decoded.append((record, try Self.envelope(from: record)))
            } catch {
                try CloudSyncRecordCoding.quarantine(record, error: error, in: safety)
                rejected.insert(record.recordID.recordName)
            }
        }
        decoded.removeAll { rejected.contains($0.0.recordID.recordName) }
        let identical = try Set(
            decoded.compactMap { _, envelope -> SettingsRecordKey? in
                guard isConflict else { return nil }
                return try journal.envelope(for: envelope.key) == envelope ? envelope.key : nil
            })
        let result = try applyRemote(
            decoded.map { $0.1 },
            beforeSave: {
                for (record, envelope) in decoded {
                    if record.recordID.recordName == envelope.key.recordName {
                        try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
                        if identical.contains(envelope.key) {
                            try journal.markUploaded(envelope.key, version: envelope.version)
                        }
                    } else {
                        // Legacy Guardian data has no canonical CloudKit record; never reuse its system fields.
                        try journal.markNeedsUpload([envelope.key])
                    }
                    try safety.clearQuarantine(recordName: record.recordID.recordName)
                }
                for id in deletions where id.zoneID == zoneID {
                    guard let key = SettingsRecordKey(recordName: id.recordName), try journal.envelope(for: key) != nil
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
        if !result.acceptedKeys.isEmpty { didApplyRemote?(result.snapshot, result.acceptedKeys) }
    }

    private func handleSentChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        for record in changes.savedRecords where record.recordID.zoneID == zoneID {
            guard try !safety.isUploadBlocked(recordName: record.recordID.recordName) else { continue }
            let envelope = try Self.envelope(from: record)
            try journal.markUploaded(envelope.key, version: envelope.version)
            try journal.updateSystemFields(Self.systemFields(of: record), for: envelope.key)
            try? FileManager.default.removeItem(at: Self.assetURL(for: envelope.key))
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
            lifecycle.terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    nonisolated static func acceptsRecordType(_ type: String) -> Bool {
        type == recordType || type == sshRecordType || type == sftpRecordType
    }

    private nonisolated static func recordType(for kind: SettingsRecordKind) -> String {
        switch kind {
        case .ssh: sshRecordType
        case .sftp: sftpRecordType
        default: recordType
        }
    }

    public nonisolated static func makeRecord(
        _ outgoing: SettingsOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record = try CloudSyncRecordCoding.makeRecord(
            type: recordType(for: envelope.key.kind), id: recordID, systemFields: outgoing.systemFieldsData)
        guard record.recordType == recordType(for: envelope.key.kind), record.recordID == recordID else {
            throw SettingsSyncPersistenceError.invalidEnvelope(recordID.recordName)
        }
        let payload = try SettingsSyncCodec.encode(envelope)
        record["formatVersion"] = NSNumber(value: envelope.formatVersion)
        record["kind"] = envelope.key.kind.rawValue as NSString
        record["entityID"] = envelope.key.id as NSString
        record["modifiedAt"] = envelope.version.modifiedAt as NSDate
        record["counter"] = NSNumber(value: Int64(clamping: envelope.version.counter))
        record["writerID"] = envelope.version.writerID.uuidString.lowercased() as NSString
        record["isDeleted"] = NSNumber(value: envelope.isDeleted)
        try CloudSyncRecordCoding.setPayload(payload, on: record, assetURL: assetURL(for: envelope.key))
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> SettingsEnvelope {
        let data = try CloudSyncRecordCoding.validatedPayloadData(
            from: record, invalidEnvelope: SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName))
        try CloudSyncRecordCoding.validateFormat(in: data, supported: SettingsEnvelope.currentFormatVersion)
        let envelope = try SettingsSyncCodec.decode(data)
        guard record.recordType == recordType(for: envelope.key.kind),
            envelope.key.recordName == record.recordID.recordName,
            envelope.isValid || envelope.isValidLegacyGuardianRecord
        else {
            throw SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return envelope.canonicalized
    }

    public nonisolated static func payloadData(from record: CKRecord) throws -> Data {
        try CloudSyncRecordCoding.payloadData(
            from: record, invalidEnvelope: SettingsSyncPersistenceError.invalidEnvelope(record.recordID.recordName))
    }

    public nonisolated static func systemFields(of record: CKRecord) throws -> Data {
        try CloudSyncRecordCoding.systemFields(of: record)
    }

    private nonisolated static func assetURL(for key: SettingsRecordKey) throws -> URL {
        try CloudSyncRecordCoding.assetURL(recordName: key.recordName, directoryName: "Termind/SettingsSyncAssets")
    }

}

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
    // Older clients filter by record type before decoding, so they can ignore SFTP safely.
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

    private func addPendingChanges(_ keys: Set<SettingsRecordKey>) {
        lifecycle.enqueue(keys.filter { $0.kind.participatesInSync }.map(\.recordName))
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

    private func applyRemote(_ envelopes: [SettingsEnvelope]) throws
        -> (
            snapshot: SettingsSyncSnapshot, acceptedKeys: Set<SettingsRecordKey>,
            needsUpload: Set<SettingsRecordKey>
        )
    {
        let result = try persistence.applyRemote(envelopes)
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
        guard lifecycle.accepts(engine), lifecycle.isReadyToSend else { return nil }
        do { try migrateSecrets() } catch {
            status = .failed(error.localizedDescription)
            return nil
        }
        let pending = engine.state.pendingRecordZoneChanges.filter {
            context.options.scope.contains($0)
        }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) {
            [weak self] recordID in
            guard let self else { return nil }
            return await self.recordToSave(recordID)
        }
    }

    @MainActor
    private func recordToSave(_ recordID: CKRecord.ID) -> CKRecord? {
        guard recordID.zoneID == zoneID, let key = SettingsRecordKey(recordName: recordID.recordName),
            let outgoing = try? journal.outgoingEntry(for: key)
        else { return nil }
        do { return try Self.makeRecord(outgoing, recordID: recordID) } catch {
            lifecycle.terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
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
        var recordsByKey: [SettingsRecordKey: CKRecord] = [:]
        var legacyGuardianKeys = Set<SettingsRecordKey>()
        var envelopes: [SettingsEnvelope] = []
        var quarantinedError: String?
        for modification in changes.modifications {
            let record = modification.record
            guard Self.acceptsRecordType(record.recordType), record.recordID.zoneID == zoneID else {
                continue
            }
            if let key = SettingsRecordKey(recordName: record.recordID.recordName),
                !key.kind.participatesInSync
            {
                try journal.clearQuarantine(recordName: record.recordID.recordName)
                continue
            }
            do {
                let envelope = try Self.envelope(from: record)
                try journal.clearQuarantine(recordName: record.recordID.recordName)
                let sourceKey = SettingsRecordKey(recordName: record.recordID.recordName)
                if sourceKey == envelope.key {
                    recordsByKey[envelope.key] = record
                } else {
                    legacyGuardianKeys.insert(envelope.key)
                }
                envelopes.append(envelope)
            } catch {
                try journal.quarantine(
                    recordName: record.recordID.recordName,
                    payloadData: (try? Self.payloadData(from: record)) ?? Data(),
                    reason: error.localizedDescription
                )
                quarantinedError = error.localizedDescription
            }
        }

        let result = try applyRemote(envelopes)
        for (key, record) in recordsByKey {
            try journal.updateSystemFields(Self.systemFields(of: record), for: key)
        }
        // An accepted legacy value has no canonical CloudKit record behind it.
        // Publish the normalized Guardian record so current clients converge.
        let bridgeKeys = legacyGuardianKeys.intersection(result.acceptedKeys)
        let needsUpload = result.needsUpload.union(bridgeKeys)
        try journal.markNeedsUpload(needsUpload)

        // Physical deletes are not part of the protocol; recreate the local
        let physicallyDeleted = Set(
            changes.deletions.compactMap {
                $0.recordID.zoneID == zoneID ? SettingsRecordKey(recordName: $0.recordID.recordName) : nil
            }
        ).filter { (try? journal.envelope(for: $0)) != nil }
        try journal.markNeedsUpload(physicallyDeleted)
        addPendingChanges(needsUpload.union(physicallyDeleted))
        try context.save()
        if !result.acceptedKeys.isEmpty {
            didApplyRemote?(result.snapshot, result.acceptedKeys)
        }
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
                let result = try applyRemote([serverEnvelope])
                try journal.updateSystemFields(
                    Self.systemFields(of: serverRecord), for: serverEnvelope.key
                )
                if localEnvelope == serverEnvelope {
                    try journal.markUploaded(
                        serverEnvelope.key, version: serverEnvelope.version
                    )
                } else {
                    try journal.markNeedsUpload(result.needsUpload)
                    addPendingChanges(result.needsUpload)
                }
                try context.save()
                if !result.acceptedKeys.isEmpty {
                    didApplyRemote?(result.snapshot, result.acceptedKeys)
                }
            } else if error.code == .zoneNotFound {
                try lifecycle.handleZoneDeletion()
            } else if !CloudSyncLifecycle.isRetryable(error) {
                lifecycle.terminalError = error.localizedDescription
                status = .failed(error.localizedDescription)
            }
        }
        try context.save()
    }

    nonisolated static func acceptsRecordType(_ type: String) -> Bool {
        type == recordType || type == sftpRecordType
    }

    private nonisolated static func recordType(for kind: SettingsRecordKind) -> String {
        kind == .sftp ? sftpRecordType : recordType
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

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
    // Keep the initial AI-sync identifiers so existing replicas remain reachable.
    public nonisolated static let zoneName = "TermindAIConfigurationV1"
    public nonisolated static let recordType = "AIConfigurationItem"
    // Older clients filter by record type before decoding, so they can ignore newer preferences safely.
    public nonisolated static let sshRecordType = "SSHPreferencesItem"
    public nonisolated static let sftpRecordType = "SFTPPreferencesItem"
    public nonisolated static let terminalHighlightRecordType = "TerminalHighlightPreferencesItem"
    public nonisolated static let notificationRecordType = "NotificationPreferencesItem"
    public nonisolated static let workspaceRecordType = "WorkspacePreferencesItem"
    public nonisolated static let subscriptionID = "termind-ai-configuration-v1-changes"
    nonisolated static let assetDirectoryName = "Termind/SettingsSyncAssets"

    private let context: ModelContext
    private let persistence: SettingsSyncPersistence
    private let secrets: AISecretStore
    private let journal: SettingsSyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let assetCacheRoot: URL?
    private let removeAssetDirectory: (URL) throws -> Void
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    public var status: VaultSyncStatus { lifecycle.status }
    public var didApplyRemote: ((SettingsSyncSnapshot, Set<SettingsRecordKey>) -> Void)?

    public var isEnabled: Bool { lifecycle.isEnabled }

    public convenience init(
        persistence: SettingsSyncPersistence,
        secrets: AISecretStore,
        container: CKContainer = CKContainer(identifier: CloudSyncContainer.identifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = CloudSyncContainer.environmentIdentifier
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
        assetCacheRoot: URL? = nil,
        removeAssetDirectory: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        self.secrets = secrets
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

    public func noteLocalChanges(_ mutations: SettingsMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.filter { $0.kind.participatesInSync }.map(\.recordName))
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
                safety: .persistent(
                    context: context,
                    capabilityID: SettingsRecordKind.allCases.filter(\.participatesInSync)
                        .map { "\($0.rawValue):1" }.sorted().joined(separator: ";")),
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
                    handlesRecordName: {
                        guard let key = SettingsRecordKey(recordName: $0) else { return false }
                        return key.kind != .terminalHighlighting
                    })),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: CloudSyncContainer.identifier, defaults: defaults,
            enabledKey: SettingsKey.settingsSyncEnabled, defaultEnabled: SettingsKey.defaultSettingsSyncEnabled,
            environmentKey: SettingsKey.settingsSyncEnvironment, environmentIdentifier: environmentIdentifier,
            authorizeUploads: { [secrets] in secrets.uploadsAuthorized = $0 },
            beforeSend: { [weak self] in try self?.migrateSecrets() },
            receiveSnapshot: { [weak self] in try self?.receiveRemoteRecords($0, deletions: $1) })
    }

    private func completePendingAssetPurge() throws {
        try CloudSyncRecordCoding.completePendingAssetPurge(
            directoryName: Self.assetDirectoryName, context: context, cacheRoot: assetCacheRoot,
            removeItem: removeAssetDirectory)
    }

    private func migrateSecrets() throws {
        let config = try persistence.load().configuration
        try secrets.migrate(
            Set(
                config.providers.flatMap { [$0.credentialRef, $0.vertex.credentialRef] }
                    + config.mcpServers.map(\.credentialRef)))
    }

    /// Accepted remote credential references become eligible for Keychain synchronization.
    private func applyRemote(
        _ envelopes: [SettingsEnvelope], deletions: Set<SettingsRecordKey>, beforeSave: () throws -> Void
    ) throws -> (snapshot: SettingsSyncSnapshot, acceptedKeys: Set<SettingsRecordKey>) {
        let result = try persistence.applyRemote(envelopes, deletions: deletions, beforeSave: beforeSave)
        let references = envelopes.filter { result.acceptedKeys.contains($0.key) }.flatMap { envelope -> [String] in
            switch envelope.payload {
            case .provider(let value): [value.credentialRef, value.vertex?.credentialRef ?? ""]
            case .mcpServer(let value): [value.credentialRef]
            default: []
            }
        }
        try secrets.acceptRemoteReferences(Set(references))
        return (result.snapshot, result.acceptedKeys)
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

    func receiveRemoteRecords(
        _ records: [CKRecord], deletions: [CKRecord.ID] = [], isConflict: Bool = false
    ) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        // The removed feature shares this zone, but its separate record type is ignored
        // before reconciliation or payload validation, including conflict deliveries.
        let activeRecords = records.filter {
            $0.recordType != Self.terminalHighlightRecordType
                && SettingsRecordKey(recordName: $0.recordID.recordName)?.kind != .terminalHighlighting
        }
        let activeDeletions = deletions.filter {
            SettingsRecordKey(recordName: $0.recordName)?.kind != .terminalHighlighting
        }
        let reconciled = try lifecycle.reconcileRemoteChanges(records: activeRecords, deletions: activeDeletions)
        let (records, deletions) = (reconciled.records, reconciled.deletions)
        lifecycle.noteRecordsObserved(records, excluding: deletions)
        let allDeletedKeys = Set(
            deletions.compactMap { id -> SettingsRecordKey? in
                guard id.zoneID == zoneID else { return nil }
                return SettingsRecordKey(recordName: id.recordName)
            })
        // Historical and legacy Guardian deletions only retire cleanup tombstones; they never delete local data.
        let deletedKeys = allDeletedKeys.filter { $0.kind.participatesInSync && !$0.isLegacyGuardianRole }
        let deletedNames = Set(allDeletedKeys.map(\.recordName))
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let decoded: [(record: CKRecord, envelope: SettingsEnvelope)] = try decodeCloudSyncRecords(
            records.filter { !deletedNames.contains($0.recordID.recordName) },
            included: { record in
                guard record.recordID.zoneID == zoneID,
                    isConflict || Self.acceptsRecordType(record.recordType)
                else { return false }
                return SettingsRecordKey(recordName: record.recordID.recordName) != nil
            },
            decode: Self.validatedEnvelope,
            quarantine: {
                try CloudSyncRecordCoding.quarantine(
                    $0, error: $1, in: safety,
                    nativeFields: $0.recordType == TerminalThemeCloudRecordV1.themeRecordType
                        || $0.recordType == TerminalThemeCloudRecordV1.selectionRecordType
                        || SettingsRecordKey(recordName: $0.recordID.recordName).map {
                            TerminalThemeCloudRecordV1.recordType(for: $0.kind) != nil
                        } == true)
            },
            logFailure: { lifecycle.logFailure($0, stage: "decode-quarantine") })
        let result = try applyRemote(
            decoded.map { $0.1.canonicalized }, deletions: deletedKeys,
            beforeSave: {
                for (record, sourceEnvelope) in decoded {
                    let envelope = sourceEnvelope.canonicalized
                    if sourceEnvelope.isDeleted,
                        !sourceEnvelope.key.kind.participatesInSync || sourceEnvelope.key.isLegacyGuardianRole
                    {
                        try journal.queueHistoricalDeletion(sourceEnvelope)
                    }
                    if sourceEnvelope.key.kind.participatesInSync || sourceEnvelope.isDeleted {
                        let current = try journal.cloudRecords().first {
                            $0.mutation.recordName == record.recordID.recordName
                        }
                        try cloud.observed(
                            record.recordID.recordName, version: envelope.version, current: current)
                    }
                    if record.recordID.recordName == envelope.key.recordName,
                        envelope.key.kind.participatesInSync
                    {
                        try journal.updateSystemFields(
                            CloudSyncRecordCoding.systemFields(of: record), for: envelope.key)
                        if try journal.envelope(for: envelope.key) == envelope {
                            try journal.markUploaded(envelope.key, version: envelope.version)
                        }
                    } else if sourceEnvelope.key.isLegacyGuardianRole {
                        // Legacy Guardian data has no canonical CloudKit record; never reuse its system fields.
                        try journal.markNeedsUpload([envelope.key])
                    }
                    try safety.clearQuarantine(recordName: record.recordID.recordName)
                }
                try journal.acknowledgeRemoteDeletions(allDeletedKeys, scope: scope)
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

    nonisolated static func acceptsRecordType(_ type: String) -> Bool {
        type == recordType || type == sshRecordType || type == sftpRecordType || type == workspaceRecordType
            || type == notificationRecordType
            || type == TerminalThemeCloudRecordV1.themeRecordType
            || type == TerminalThemeCloudRecordV1.selectionRecordType
    }

    private nonisolated static func recordType(for kind: SettingsRecordKind) -> String {
        switch kind {
        case .ssh: sshRecordType
        case .sftp: sftpRecordType
        case .workspace: workspaceRecordType
        case .notifications: notificationRecordType
        case .terminalHighlighting: terminalHighlightRecordType
        case .terminalCustomTheme: TerminalThemeCloudRecordV1.themeRecordType
        case .terminalThemeSelection: TerminalThemeCloudRecordV1.selectionRecordType
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
        if TerminalThemeCloudRecordV1.recordType(for: envelope.key.kind) != nil {
            try TerminalThemeCloudRecordV1.write(envelope, into: record, assetURL: { try assetURL(for: envelope.key) })
            return record
        }
        CloudSyncRecordCoding.setMetadata(
            on: record, formatVersion: envelope.formatVersion, kind: envelope.key.kind.rawValue,
            entityID: envelope.key.id, version: envelope.version, isDeleted: envelope.isDeleted)
        let payload = try SettingsSyncCodec.encode(envelope)
        try CloudSyncRecordCoding.setPayload(payload, on: record, assetURL: assetURL(for: envelope.key))
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> SettingsEnvelope {
        try validatedEnvelope(from: record).canonicalized
    }

    private nonisolated static func validatedEnvelope(from record: CKRecord) throws -> SettingsEnvelope {
        if record.recordType == TerminalThemeCloudRecordV1.themeRecordType
            || record.recordType == TerminalThemeCloudRecordV1.selectionRecordType
        {
            return try TerminalThemeCloudRecordV1.read(record)
        }
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
        return envelope
    }

    private nonisolated static func assetURL(for key: SettingsRecordKey) throws -> URL {
        try CloudSyncRecordCoding.assetURL(recordName: key.recordName, directoryName: assetDirectoryName)
    }
}

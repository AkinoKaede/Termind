import CloudKit
import CryptoKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

@MainActor
@Observable
public final class VaultSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public nonisolated static let containerIdentifier = "iCloud.com.akinokaede.termind"
    public nonisolated static let zoneName = "TermindVaultV1"
    public nonisolated static let recordType = "VaultItem"
    public nonisolated static let subscriptionID = "termind-vault-v1-changes"
    public nonisolated static let inlinePayloadLimit = 700_000

    private let context: ModelContext
    private let persistence: HostPersistence
    private let journal: VaultSyncJournal
    private let container: CKContainer
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    private var engine: CKSyncEngine?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var isReadyToSend = false
    private var isStarted = false
    private var terminalError: String?

    public private(set) var status: VaultSyncStatus = .checkingAccount
    public var didApplyRemote: ((VaultSnapshot, Set<VaultRecordKey>) -> Void)?

    public var isEnabled: Bool {
        guard
            defaults.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool
                ?? SettingsKey.defaultICloudSyncEnabled
        else { return false }
        return defaults.object(forKey: SettingsKey.vaultSyncEnabled) as? Bool
            ?? SettingsKey.defaultVaultSyncEnabled
    }

    public init(
        context: ModelContext,
        container: CKContainer = CKContainer(identifier: VaultSyncCoordinator.containerIdentifier),
        defaults: UserDefaults = .standard,
        environmentIdentifier: String = VaultSyncCoordinator.runtimeEnvironmentIdentifier
    ) {
        self.context = context
        persistence = HostPersistence(context: context)
        journal = VaultSyncJournal(context: context)
        self.container = container
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()
    }

    public nonisolated static var runtimeEnvironmentIdentifier: String {
        Bundle.main.object(forInfoDictionaryKey: "TermindCloudKitEnvironment") as? String
            ?? "Unknown"
    }

    public func start() {
        guard isEnabled else {
            pause()
            return
        }
        guard !isStarted else { return }
        isStarted = true
        run { [weak self] in try await self?.prepareAndSynchronize() }
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: SettingsKey.vaultSyncEnabled)
        if enabled { start() } else { pause() }
    }

    public func pause() {
        operationID = UUID()
        isReadyToSend = false
        operation?.cancel()
        operation = nil
        isStarted = false
        let engine = self.engine
        self.engine = nil
        status = .paused
        if let engine { Task { await engine.cancelOperations() } }
    }

    public func retry() {
        guard isEnabled else { return }
        terminalError = nil
        if engine == nil {
            isStarted = false
            start()
        } else {
            run { [weak self] in try await self?.synchronizeNow() }
        }
    }

    public func noteLocalChanges(_ mutations: VaultMutationSet) {
        guard !mutations.isEmpty else { return }
        addPendingChanges(mutations.keys)
        guard isEnabled, engine != nil else { return }
        run { [weak self] in try await self?.sendPendingChanges() }
    }

    public func confirmAccountSwitchMerge() {
        guard isEnabled else { return }
        do {
            let state = try journal.state()
            guard let pendingUser = state.pendingUserRecordName else { return }
            try journal.markAllLiveRecordsNeedsUploadForNewAccount()
            state.boundUserRecordName = pendingUser
            state.pendingUserRecordName = nil
            try context.save()
            engine = nil
            isStarted = false
            start()
        } catch {
            context.rollback()
            status = .failed(error.localizedDescription)
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        let id = UUID()
        operationID = id
        operation = Task { [weak self] in
            defer { if self?.operationID == id { self?.operation = nil } }
            do { try await body() } catch is CancellationError {} catch {
                if self?.operationID == id { self?.status = Self.status(for: error) }
            }
        }
    }

    private func prepareAndSynchronize() async throws {
        let id = operationID
        status = .checkingAccount
        let accountStatus = try await container.accountStatus()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        guard accountStatus == .available else {
            status = .unavailable(Self.accountStatusDescription(accountStatus))
            isStarted = false
            return
        }

        let userRecordID = try await container.userRecordID()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        let currentUser = userRecordID.recordName
        let state = try journal.state()
        if let boundUser = state.boundUserRecordName, boundUser != currentUser {
            state.pendingUserRecordName = currentUser
            try context.save()
            status = .accountChangeConfirmationRequired
            isStarted = false
            return
        }
        state.boundUserRecordName = currentUser
        state.pendingUserRecordName = nil

        try prepareForCurrentEnvironment()

        let serialization = state.engineStateData.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = true
        configuration.subscriptionID = Self.subscriptionID
        let engine = CKSyncEngine(configuration)
        self.engine = engine

        let pending = try journal.pendingEnvelopes()
        addPendingChanges(Set(pending.map(\.key)))
        try context.save()

        // Zone creation is idempotent and deliberately precedes the first fetch;
        // no local record is sent until the server side has been read.
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await container.privateCloudDatabase.modifyRecordZones(
            saving: [zone], deleting: []
        )
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        guard self.engine === engine, isEnabled, !Task.isCancelled else { return }
        isReadyToSend = true
        try await sendPendingChanges()
        try updateUpToDateStatus()
    }

    private func synchronizeNow() async throws {
        guard let engine else { return }
        status = .syncing(pendingCount: try journal.pendingEnvelopes().count)
        try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
        guard self.engine === engine, isEnabled, !Task.isCancelled else { return }
        isReadyToSend = true
        try await sendPendingChanges()
        try updateUpToDateStatus()
    }

    private func sendPendingChanges() async throws {
        guard let engine, isEnabled, isReadyToSend else { return }
        let pending = try journal.pendingEnvelopes()
        guard !pending.isEmpty else { return }
        addPendingChanges(Set(pending.map(\.key)))
        status = .syncing(pendingCount: pending.count)
        try await engine.sendChanges()
    }

    private func addPendingChanges(_ keys: Set<VaultRecordKey>) {
        guard let engine else { return }
        engine.state.add(
            pendingRecordZoneChanges: keys.map {
                .saveRecord(CKRecord.ID(recordName: $0.recordName, zoneID: zoneID))
            })
    }

    private func updateUpToDateStatus() throws {
        if let quarantineReason = try journal.firstQuarantineReason() {
            status = .failed(quarantineReason)
            return
        }
        if let terminalError {
            status = .failed(terminalError)
            return
        }
        let pendingCount = try journal.pendingEnvelopes().count
        let state = try journal.state()
        if pendingCount == 0 {
            state.lastSuccessfulSync = .now
            try context.save()
            status = .upToDate(lastSuccessfulSync: state.lastSuccessfulSync)
        } else {
            status = .syncing(pendingCount: pendingCount)
        }
    }

    public nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)]))
    }

    // MARK: CKSyncEngineDelegate

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
        guard self.engine === engine, isEnabled, isReadyToSend else { return nil }
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
        guard recordID.zoneID == zoneID, let key = VaultRecordKey(recordName: recordID.recordName),
            let outgoing = try? journal.outgoingEntry(for: key)
        else { return nil }
        do { return try Self.makeRecord(outgoing, recordID: recordID) } catch {
            terminalError = error.localizedDescription
            status = .failed(error.localizedDescription)
            return nil
        }
    }

    @MainActor
    private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) async {
        guard self.engine === engine, isEnabled else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                let state = try journal.state()
                state.engineStateData = try JSONEncoder().encode(update.stateSerialization)
                try context.save()

            case .accountChange(let change):
                try handleAccountChange(change)

            case .fetchedRecordZoneChanges(let changes):
                try handleFetchedChanges(changes, engine: engine)

            case .fetchedDatabaseChanges(let changes):
                if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                    try handleZoneDeletion(engine: engine)
                }

            case .sentRecordZoneChanges(let changes):
                try handleSentChanges(changes, engine: engine)

            case .didFetchChanges, .didSendChanges:
                try updateUpToDateStatus()

            default:
                break
            }
        } catch {
            context.rollback()
            status = Self.status(for: error)
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) throws {
        let state = try journal.state()
        switch change.changeType {
        case .signIn(let currentUser):
            if let bound = state.boundUserRecordName, bound != currentUser.recordName {
                stopEngineForAccountChange()
                state.pendingUserRecordName = currentUser.recordName
                status = .accountChangeConfirmationRequired
            }
        case .signOut:
            stopEngineForAccountChange()
            status = .unavailable(String(localized: "Sign in to iCloud to sync the Vault."))
        case .switchAccounts(_, let currentUser):
            stopEngineForAccountChange()
            state.pendingUserRecordName = currentUser.recordName
            status = .accountChangeConfirmationRequired
        @unknown default:
            stopEngineForAccountChange()
            status = .unavailable(String(localized: "The iCloud account changed."))
        }
        try context.save()
    }

    private func stopEngineForAccountChange() {
        isReadyToSend = false
        let activeEngine = engine
        engine = nil
        isStarted = false
        if let activeEngine { Task { await activeEngine.cancelOperations() } }
    }

    private func handleFetchedChanges(
        _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges, engine: CKSyncEngine
    ) throws {
        var recordsByKey: [VaultRecordKey: CKRecord] = [:]
        var envelopes: [VaultEnvelope] = []
        var quarantinedError: String?
        for modification in changes.modifications {
            let record = modification.record
            guard record.recordType == Self.recordType, record.recordID.zoneID == zoneID else {
                continue
            }
            do {
                let envelope = try Self.envelope(from: record)
                try journal.clearQuarantine(recordName: record.recordID.recordName)
                recordsByKey[envelope.key] = record
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

        let result = try persistence.applyRemote(envelopes)
        for (key, record) in recordsByKey {
            try journal.updateSystemFields(Self.systemFields(of: record), for: key)
        }
        try journal.markNeedsUpload(result.needsUpload)

        // Physical deletes are not part of the protocol; recreate the local
        // envelope instead of converting a console accident into data loss.
        let physicallyDeleted = Set(
            changes.deletions.compactMap {
                $0.recordID.zoneID == zoneID ? VaultRecordKey(recordName: $0.recordID.recordName) : nil
            }
        ).filter { (try? journal.envelope(for: $0)) != nil }
        try journal.markNeedsUpload(physicallyDeleted)
        addPendingChanges(result.needsUpload.union(physicallyDeleted))
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
                let result = try persistence.applyRemote([serverEnvelope])
                try journal.updateSystemFields(
                    Self.systemFields(of: serverRecord), for: serverEnvelope.key
                )
                if localEnvelope == serverEnvelope {
                    // Clearing environment-specific system fields intentionally
                    // turns an existing identical record into a create attempt.
                    // The server copy proves it is already uploaded.
                    try journal.markUploaded(
                        serverEnvelope.key, version: serverEnvelope.version
                    )
                } else {
                    try journal.markNeedsUpload(result.needsUpload)
                    addPendingChanges(result.needsUpload)
                }
                if !result.acceptedKeys.isEmpty {
                    didApplyRemote?(result.snapshot, result.acceptedKeys)
                }
            } else if error.code == .zoneNotFound {
                try handleZoneDeletion(engine: engine)
            } else if !Self.isRetryable(error) {
                terminalError = error.localizedDescription
                status = .failed(error.localizedDescription)
            }
        }
        try context.save()
    }

    private func handleZoneDeletion(engine: CKSyncEngine) throws {
        try journal.markAllEntriesNeedsUploadAfterZoneReset()
        let zone = CKRecordZone(zoneID: zoneID)
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
        addPendingChanges(Set((try journal.pendingEnvelopes()).map(\.key)))
        try context.save()
    }

    /// The sandbox is shared when a Debug build is replaced by TestFlight.
    /// CKSyncEngine serialization and CKRecord system fields are not: they are
    /// scoped to Development or Production. Rebind once per environment while
    /// retaining every local envelope and its conflict-resolution version.
    private func prepareForCurrentEnvironment() throws {
        guard
            defaults.string(forKey: SettingsKey.vaultSyncEnvironment)
                != environmentIdentifier
        else { return }

        try journal.markAllEntriesNeedsUploadAfterEnvironmentChange()
        try context.save()
        defaults.set(environmentIdentifier, forKey: SettingsKey.vaultSyncEnvironment)
        terminalError = nil
    }

    // MARK: Record coding

    public nonisolated static func makeRecord(
        _ outgoing: VaultOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record: CKRecord
        if let data = outgoing.systemFieldsData,
            let restored = try Self.record(fromSystemFields: data)
        {
            record = restored
        } else {
            record = CKRecord(recordType: recordType, recordID: recordID)
        }
        let payload = VaultSyncCodec.encode(envelope)
        record["formatVersion"] = NSNumber(value: envelope.formatVersion)
        record["kind"] = envelope.key.kind.rawValue as NSString
        record["entityID"] = envelope.key.id.uuidString.lowercased() as NSString
        record["modifiedAt"] = envelope.version.modifiedAt as NSDate
        record["counter"] = NSNumber(value: Int64(clamping: envelope.version.counter))
        record["writerID"] = envelope.version.writerID.uuidString.lowercased() as NSString
        record["isDeleted"] = NSNumber(value: envelope.isDeleted)
        record["payloadHash"] = SHA256.hash(data: payload).hexString as NSString
        if payload.count > inlinePayloadLimit {
            let url = try assetURL(for: envelope.key)
            try payload.write(to: url, options: .atomic)
            record["payload"] = nil
            record["payloadAsset"] = CKAsset(fileURL: url)
        } else {
            record["payload"] = payload as NSData
            record["payloadAsset"] = nil
        }
        return record
    }

    public nonisolated static func envelope(from record: CKRecord) throws -> VaultEnvelope {
        let data = try payloadData(from: record)
        let expectedHash = record["payloadHash"] as? String
        guard expectedHash == SHA256.hash(data: data).hexString else {
            throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        let envelope = try VaultSyncCodec.decode(data)
        guard envelope.key.recordName == record.recordID.recordName, envelope.isValid else {
            throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
        }
        return envelope
    }

    public nonisolated static func payloadData(from record: CKRecord) throws -> Data {
        if let inline = record["payload"] as? Data { return inline }
        if let asset = record["payloadAsset"] as? CKAsset, let url = asset.fileURL {
            return try Data(contentsOf: url)
        }
        throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
    }

    public nonisolated static func systemFields(of record: CKRecord) throws -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private nonisolated static func record(fromSystemFields data: Data) throws -> CKRecord? {
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private nonisolated static func assetURL(for key: VaultRecordKey) throws -> URL {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Termind/VaultSyncAssets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: key.recordName.replacingOccurrences(of: "/", with: "-"))
    }

    private nonisolated static func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .resultsTruncated:
            true
        default: false
        }
    }

    private nonisolated static func status(for error: any Error) -> VaultSyncStatus {
        if let cloudError = error as? CKError {
            if cloudError.code == .notAuthenticated {
                return .unavailable(String(localized: "Sign in to iCloud to sync the Vault."))
            }
            if isRetryable(cloudError) { return .syncing(pendingCount: 0) }
        }
        return .failed(error.localizedDescription)
    }

    private nonisolated static func accountStatusDescription(
        _ status: CKAccountStatus
    ) -> String {
        switch status {
        case .noAccount: String(localized: "Sign in to iCloud to sync the Vault.")
        case .restricted: String(localized: "iCloud access is restricted on this Mac.")
        case .couldNotDetermine: String(localized: "The iCloud account could not be checked.")
        case .temporarilyUnavailable: String(localized: "iCloud is temporarily unavailable.")
        case .available: ""
        @unknown default: String(localized: "iCloud is unavailable.")
        }
    }
}

extension SHA256.Digest {
    fileprivate nonisolated var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

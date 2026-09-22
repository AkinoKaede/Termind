import CloudKit
import Foundation
import TermindApplication
import TermindDomain

/// A value projection of journal state; persistent models remain owned by Persistence.
struct CloudSyncState {
    var engineStateData: Data?
    var boundUserRecordName: String?
    var pendingUserRecordName: String?
    var lastSuccessfulSync: Date?
}

@MainActor
struct CloudSyncLifecycleStore {
    var state: () throws -> CloudSyncState
    var updateState: (CloudSyncState) throws -> Void
    var save: () throws -> Void
    var rollback: () -> Void
    var pendingRecordNames: (CloudSyncScope) throws -> [String]
    var safety: CloudSyncLifecycleSafety
    var resetForNewAccount: () throws -> Void
    var resetForZone: () throws -> Void
    var resetForEnvironment: () throws -> Void
}

@MainActor
protocol CloudSyncEngineSession: AnyObject {
    func fetch(in zoneID: CKRecordZone.ID) async throws
    func send() async throws
    func cancel() async
    func enqueue(_ recordNames: [String], in zoneID: CKRecordZone.ID)
    func removePending(_ recordNames: Set<String>, in zoneID: CKRecordZone.ID)
    func recreateZone(_ zoneID: CKRecordZone.ID)
}

extension CKSyncEngine: CloudSyncEngineSession {
    func fetch(in zoneID: CKRecordZone.ID) async throws {
        try await fetchChanges(.init(scope: .zoneIDs([zoneID])))
    }
    func send() async throws { try await sendChanges() }
    func cancel() async { await cancelOperations() }
    func enqueue(_ recordNames: [String], in zoneID: CKRecordZone.ID) {
        state.add(pendingRecordZoneChanges: recordNames.map { .saveRecord(.init(recordName: $0, zoneID: zoneID)) })
    }
    func removePending(_ recordNames: Set<String>, in zoneID: CKRecordZone.ID) {
        state.remove(
            pendingRecordZoneChanges: state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let id):
                    id.zoneID == zoneID && recordNames.contains(id.recordName)
                case .deleteRecord(let id):
                    // No physical deletes belong to this protocol, including restored legacy queue entries.
                    id.zoneID == zoneID
                @unknown default: false
                }
            })
    }
    func recreateZone(_ zoneID: CKRecordZone.ID) {
        state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
    }
}

@MainActor
struct CloudSyncTransport {
    var accountStatus: () async throws -> CKAccountStatus
    var userRecordName: () async throws -> String
    var createZone: () async throws -> Void
    var makeEngine: (Data?) throws -> any CloudSyncEngineSession

    static func live(
        container: CKContainer, zoneID: CKRecordZone.ID, subscriptionID: String, delegate: any CKSyncEngineDelegate
    ) -> Self {
        Self(
            accountStatus: { try await container.accountStatus() },
            userRecordName: { try await container.userRecordID().recordName },
            createZone: {
                _ = try await container.privateCloudDatabase.modifyRecordZones(
                    saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            },
            makeEngine: { [weak delegate] data in
                guard let delegate else { throw CancellationError() }
                let serialization = data.flatMap {
                    try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
                }
                var configuration = CKSyncEngine.Configuration(
                    database: container.privateCloudDatabase, stateSerialization: serialization, delegate: delegate)
                configuration.automaticallySync = true
                configuration.subscriptionID = subscriptionID
                return CKSyncEngine(configuration)
            })
    }
}

/// One instance per category: only implementation is shared, never account or engine state.
@MainActor @Observable
final class CloudSyncLifecycle {
    let store: CloudSyncLifecycleStore
    let transport: CloudSyncTransport
    let zoneID: CKRecordZone.ID
    private let containerIdentifier: String
    private let defaults: UserDefaults
    private let enabledKey: String
    private let defaultEnabled: Bool
    private let environmentKey: String
    private let environmentIdentifier: String
    private let signInMessage: () -> String
    private let authorizeUploads: (Bool) -> Void
    private let beforeSend: () throws -> Void
    private(set) var engine: (any CloudSyncEngineSession)?
    private(set) var scope: CloudSyncScope?
    private(set) var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var isStarted = false
    private var zonePrepared = false
    // Explicit fetch/send calls and automatic engine events can overlap.
    private var fetching = 0
    private var sending = 0
    private var fetchFailed = false
    private(set) var isReadyToSend = false
    var terminalError: String?
    var status: VaultSyncStatus = .checkingAccount

    init(
        store: CloudSyncLifecycleStore, transport: CloudSyncTransport, zoneID: CKRecordZone.ID,
        containerIdentifier: String, defaults: UserDefaults, enabledKey: String, defaultEnabled: Bool,
        environmentKey: String, environmentIdentifier: String, signInMessage: @escaping () -> String,
        authorizeUploads: @escaping (Bool) -> Void = { _ in }, beforeSend: @escaping () throws -> Void = {}
    ) {
        self.store = store
        self.transport = transport
        self.zoneID = zoneID
        self.containerIdentifier = containerIdentifier
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.defaultEnabled = defaultEnabled
        self.environmentKey = environmentKey
        self.environmentIdentifier = environmentIdentifier
        self.signInMessage = signInMessage
        self.authorizeUploads = authorizeUploads
        self.beforeSend = beforeSend
    }

    var isEnabled: Bool {
        (defaults.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool ?? SettingsKey.defaultICloudSyncEnabled)
            && (defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled)
    }

    func start() {
        guard isEnabled else {
            pause()
            return
        }
        guard !isStarted else { return }
        isStarted = true
        run { [weak self] in try await self?.prepareAndSynchronize() }
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: enabledKey)
        if enabled { start() } else { pause() }
    }

    func pause() {
        retireEngine()
        status = .paused
    }

    func retry() {
        guard isEnabled else { return }
        terminalError = nil
        if engine == nil {
            isStarted = false
            start()
        } else {
            run { [weak self] in try await self?.synchronizeNow() }
        }
    }

    func noteLocalChanges(_ recordNames: [String]) {
        guard !recordNames.isEmpty else { return }
        do {
            try enqueue(recordNames)
            guard isEnabled, engine != nil else { return }
            run { [weak self] in
                try await self?.sendPendingChanges()
                try self?.updateUpToDateStatus()
            }
        } catch { failClosed(error) }
    }

    private func makeScope(account: String, environment: String) -> CloudSyncScope {
        CloudSyncScope(
            container: containerIdentifier, environment: environment, account: account,
            zone: zoneID.zoneName, owner: zoneID.ownerName)
    }

    private func legacyScope(for state: CloudSyncState) -> CloudSyncScope {
        makeScope(
            account: state.boundUserRecordName ?? "legacy-unbound",
            environment: defaults.string(forKey: environmentKey) ?? "Unknown")
    }

    func confirmAccountSwitchMerge() {
        guard isEnabled else { return }
        do {
            var state = try store.state()
            guard let pendingUser = state.pendingUserRecordName else { return }
            let oldScope = legacyScope(for: state)
            _ = try store.safety.prepare(oldScope, oldScope)
            try store.resetForNewAccount()
            state = try store.state()
            state.boundUserRecordName = pendingUser
            state.pendingUserRecordName = nil
            try store.updateState(state)
            try store.save()
            retireEngine()
            start()
        } catch { failClosed(error) }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        let id = UUID()
        operationID = id
        operation = Task { [weak self] in
            defer { if self?.operationID == id { self?.operation = nil } }
            do { try await body() } catch is CancellationError {} catch {
                guard let self, self.operationID == id else { return }
                if let cloudError = error as? CKError, Self.isRetryable(cloudError) {
                    self.status = self.status(for: error)
                } else {
                    self.failClosed(error)
                }
            }
        }
    }

    private func prepareAndSynchronize() async throws {
        let id = operationID
        status = .checkingAccount
        let accountStatus = try await transport.accountStatus()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        guard accountStatus == .available else {
            status = .unavailable(accountStatusDescription(accountStatus))
            isStarted = false
            return
        }
        let currentUser = try await transport.userRecordName()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        var state = try store.state()
        if let boundUser = state.boundUserRecordName, boundUser != currentUser {
            state.pendingUserRecordName = currentUser
            try store.updateState(state)
            try store.save()
            status = .accountChangeConfirmationRequired
            isStarted = false
            return
        }
        let scope = makeScope(account: currentUser, environment: environmentIdentifier)
        let requiresRefetch = try store.safety.prepare(scope, legacyScope(for: state))
        self.scope = scope
        state.boundUserRecordName = currentUser
        state.pendingUserRecordName = nil
        if requiresRefetch { state.engineStateData = nil }
        try store.updateState(state)
        if defaults.string(forKey: environmentKey) != environmentIdentifier {
            try store.resetForEnvironment()
            try store.save()
            defaults.set(environmentIdentifier, forKey: environmentKey)
            terminalError = nil
        }
        // Commit the recovery fence before constructing an automatically syncing engine.
        try setRecoveryRequired(true)
        let engine = try transport.makeEngine(store.state().engineStateData)
        self.engine = engine
        try reconcilePendingChanges()
        try store.save()
        try await transport.createZone()
        guard accepts(engine), !Task.isCancelled else { return }
        zonePrepared = true
        try await fetchAndSend(engine)
    }

    private func synchronizeNow() async throws {
        guard let engine, let scope else { return }
        status = .syncing(pendingCount: try store.pendingRecordNames(scope).count)
        try await fetchAndSend(engine)
    }

    private func fetchAndSend(_ engine: any CloudSyncEngineSession) async throws {
        try beginFetch()
        do {
            try await engine.fetch(in: zoneID)
        } catch {
            if accepts(engine) { try finishFetch(succeeded: false) }
            throw error
        }
        guard accepts(engine), !Task.isCancelled else { return }
        try finishFetch()
        try await sendPendingChanges()
        guard accepts(engine), !Task.isCancelled else { return }
        try updateUpToDateStatus()
    }

    private func sendPendingChanges() async throws {
        guard let engine, let scope, isEnabled, isReadyToSend else { return }
        try beforeSend()
        try reconcilePendingChanges()
        let pending = try store.pendingRecordNames(scope)
        guard !pending.isEmpty else { return }
        status = .syncing(pendingCount: pending.count)
        try beginSend()
        do {
            try await engine.send()
        } catch {
            if accepts(engine) { try finishSend(succeeded: false) }
            throw error
        }
        guard accepts(engine), !Task.isCancelled else { return }
        try finishSend()
    }

    private func setRecoveryRequired(_ required: Bool) throws {
        guard let scope else { throw CancellationError() }
        try store.safety.setRecoveryRequired(scope, required)
        try store.save()
    }

}

extension CloudSyncLifecycle {
    func beginFetch() throws {
        isReadyToSend = false
        authorizeUploads(false)
        if fetching == 0 { fetchFailed = false }
        fetching += 1
        try setRecoveryRequired(true)
    }

    func noteFetchFailure(_ error: CKError) {
        fetchFailed = true
        isReadyToSend = false
        authorizeUploads(false)
        status = self.status(for: error)
    }

    func finishFetch(succeeded: Bool = true) throws {
        fetching = max(0, fetching - 1)
        fetchFailed = fetchFailed || !succeeded
        try setRecoveryRequired(fetching > 0 || sending > 0 || fetchFailed)
        isReadyToSend = zonePrepared && fetching == 0 && !fetchFailed
        authorizeUploads(isReadyToSend)
    }

    func beginSend() throws {
        sending += 1
        try setRecoveryRequired(true)
    }

    func finishSend(succeeded: Bool = true) throws {
        sending = max(0, sending - 1)
        try setRecoveryRequired(!succeeded || fetching > 0 || sending > 0 || fetchFailed)
    }

    func enqueue(_ recordNames: [String]) throws {
        guard let engine, let scope else { return }
        let blocked = try store.safety.blockedRecordNames(scope)
        engine.removePending(blocked, in: zoneID)
        engine.enqueue(recordNames.filter { !blocked.contains($0) }, in: zoneID)
    }

    func reconcilePendingChanges() throws {
        guard let scope else { return }
        try enqueue(store.pendingRecordNames(scope))
    }

    func accepts(_ engine: any CloudSyncEngineSession) -> Bool { self.engine === engine && isEnabled }

    func canUpload(_ recordID: CKRecord.ID, engine: any CloudSyncEngineSession) throws -> Bool {
        guard accepts(engine), isReadyToSend, let scope, recordID.zoneID == zoneID else { return false }
        if try store.safety.isUploadBlocked(scope, recordID.recordName) {
            engine.removePending([recordID.recordName], in: zoneID)
            return false
        }
        return true
    }

    /// Synchronous materialization avoids yielding between the final fence check and batch handoff.
    func makeChangeBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], engine: any CloudSyncEngineSession,
        recordProvider: (CKRecord.ID) -> CKRecord?
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        guard accepts(engine), isReadyToSend else { return nil }
        do {
            try setRecoveryRequired(true)
            try reconcilePendingChanges()
            var records: [CKRecord] = []
            for change in pending {
                // The protocol uses tombstones. Never emit a physical deletion from a restored queue.
                guard case .saveRecord(let id) = change, try canUpload(id, engine: engine) else { continue }
                if let record = recordProvider(id) { records.append(record) }
            }
            guard accepts(engine), isReadyToSend, !records.isEmpty else { return nil }
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records)
        } catch {
            failClosed(error)
            return nil
        }
    }

    func updateUpToDateStatus() throws {
        if let terminalError {
            status = .failed(terminalError)
            return
        }
        guard isReadyToSend, let scope else { return }
        let pendingCount = try store.pendingRecordNames(scope).count
        let blockedCount = try store.safety.blockedRecordNames(scope).count
        if blockedCount > 0 {
            status = .partiallyBlocked(
                pendingCount: pendingCount, blockedCount: blockedCount,
                requiresUpdate: try store.safety.requiresNewerClient(scope))
        } else if pendingCount == 0 {
            var state = try store.state()
            state.lastSuccessfulSync = .now
            try store.updateState(state)
            try store.save()
            status = .upToDate(lastSuccessfulSync: state.lastSuccessfulSync)
        } else {
            status = .syncing(pendingCount: pendingCount)
        }
    }

    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) throws {
        var state = try store.state()
        switch change {
        case .signIn(let user):
            if let bound = state.boundUserRecordName, bound != user.recordName {
                retireEngine()
                state.pendingUserRecordName = user.recordName
                status = .accountChangeConfirmationRequired
            }
        case .signOut:
            retireEngine()
            status = .unavailable(signInMessage())
        case .switchAccounts(_, let user):
            retireEngine()
            state.pendingUserRecordName = user.recordName
            status = .accountChangeConfirmationRequired
        @unknown default:
            retireEngine()
            status = .unavailable(String(localized: "The iCloud account changed."))
        }
        try store.updateState(state)
        try store.save()
    }

    /// A delegate persistence failure must invalidate this engine, not just change a label.
    /// The already-committed recovery fence causes the next engine to fetch from the beginning.
    func failClosed(_ error: any Error) {
        store.rollback()
        retireEngine()
        status = self.status(for: error)
    }

    private func retireEngine() {
        operationID = UUID()
        operation?.cancel()
        operation = nil
        isReadyToSend = false
        authorizeUploads(false)
        isStarted = false
        zonePrepared = false
        fetching = 0
        sending = 0
        fetchFailed = false
        scope = nil
        let activeEngine = engine
        engine = nil
        if let activeEngine { Task { await activeEngine.cancel() } }
    }

    func handleZoneDeletion() throws {
        try store.resetForZone()
        engine?.recreateZone(zoneID)
        try reconcilePendingChanges()
        try store.save()
    }

    func saveEngineState(_ serialization: CKSyncEngine.State.Serialization) throws {
        var state = try store.state()
        state.engineStateData = try JSONEncoder().encode(serialization)
        try store.updateState(state)
        try store.save()
    }

    static func isRetryable(_ error: CKError) -> Bool {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .resultsTruncated:
            true
        default: false
        }
    }

    func status(for error: any Error) -> VaultSyncStatus {
        if let cloudError = error as? CKError {
            if cloudError.code == .notAuthenticated { return .unavailable(signInMessage()) }
            if Self.isRetryable(cloudError) { return .syncing(pendingCount: 0) }
        }
        return .failed(error.localizedDescription)
    }

}

extension CloudSyncLifecycle {
    private func accountStatusDescription(_ status: CKAccountStatus) -> String {
        switch status {
        case .noAccount: signInMessage()
        case .restricted: String(localized: "iCloud access is restricted on this Mac.")
        case .couldNotDetermine: String(localized: "The iCloud account could not be checked.")
        case .temporarilyUnavailable: String(localized: "iCloud is temporarily unavailable.")
        case .available: ""
        @unknown default: String(localized: "iCloud is unavailable.")
        }
    }
}

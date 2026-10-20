// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import Logging
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
    var pendingChanges: (CloudSyncScope) throws -> [CloudSyncMutation]
    var safety: CloudSyncLifecycleSafety
    var resetForNewAccount: () throws -> Void
    var resetForZone: () throws -> Void
    var resetForEnvironment: () throws -> Void
    var purge: (CloudSyncScope) throws -> Void = { _ in }
    var completePendingPurge: () throws -> Void = {}
    var replica: CloudSyncReplicaStore? = nil

    func pendingRecordNames(_ scope: CloudSyncScope) throws -> [String] {
        try pendingChanges(scope).map(\.recordName)
    }
}

@MainActor
protocol CloudSyncEngineSession: AnyObject {
    func fetch(in zoneID: CKRecordZone.ID) async throws
    func send() async throws
    func cancel() async
    func removePending(_ recordNames: Set<String>, in zoneID: CKRecordZone.ID)
    func reconcilePending(_ mutations: [CloudSyncMutation], in zoneID: CKRecordZone.ID)
    func recreateZone(_ zoneID: CKRecordZone.ID)
}

struct CloudSyncPendingReconciliation {
    var obsolete: [CKSyncEngine.PendingRecordZoneChange]
    var missing: [CKSyncEngine.PendingRecordZoneChange]

    init(current: [CKSyncEngine.PendingRecordZoneChange], mutations: [CloudSyncMutation], zoneID: CKRecordZone.ID) {
        let desired = Dictionary(uniqueKeysWithValues: mutations.map { ($0.recordName, $0.operation) })
        var retained = Set<String>()
        obsolete = current.filter { change in
            let id: CKRecord.ID
            let operation: CloudSyncMutation.Operation
            switch change {
            case .saveRecord(let value):
                id = value
                operation = .save
            case .deleteRecord(let value):
                id = value
                operation = .delete
            @unknown default: return false
            }
            guard id.zoneID == zoneID else { return false }
            guard desired[id.recordName] == operation else { return true }
            return !retained.insert(id.recordName).inserted
        }
        missing = mutations.filter { !retained.contains($0.recordName) }.map {
            let id = CKRecord.ID(recordName: $0.recordName, zoneID: zoneID)
            return $0.operation == .delete ? .deleteRecord(id) : .saveRecord(id)
        }
    }
}

extension CKSyncEngine: CloudSyncEngineSession {
    func fetch(in zoneID: CKRecordZone.ID) async throws {
        try await fetchChanges(.init(scope: .zoneIDs([zoneID])))
    }
    func send() async throws { try await sendChanges() }
    func cancel() async { await cancelOperations() }
    func removePending(_ recordNames: Set<String>, in zoneID: CKRecordZone.ID) {
        state.remove(
            pendingRecordZoneChanges: state.pendingRecordZoneChanges.filter { change in
                switch change {
                case .saveRecord(let id):
                    id.zoneID == zoneID && recordNames.contains(id.recordName)
                case .deleteRecord(let id):
                    id.zoneID == zoneID && recordNames.contains(id.recordName)
                @unknown default: false
                }
            })
    }
    func reconcilePending(_ mutations: [CloudSyncMutation], in zoneID: CKRecordZone.ID) {
        let reconciliation = CloudSyncPendingReconciliation(
            current: state.pendingRecordZoneChanges, mutations: mutations, zoneID: zoneID)
        if !reconciliation.obsolete.isEmpty {
            state.remove(pendingRecordZoneChanges: reconciliation.obsolete)
        }
        if !reconciliation.missing.isEmpty {
            state.add(pendingRecordZoneChanges: reconciliation.missing)
        }
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
    var zoneExists: () async throws -> Bool = { true }

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
            },
            zoneExists: {
                do {
                    _ = try await container.privateCloudDatabase.recordZone(for: zoneID)
                    return true
                } catch let error as CKError where error.code == .zoneNotFound {
                    return false
                }
            })
    }
}

/// One instance per category: only implementation is shared, never account or engine state.
@MainActor @Observable
final class CloudSyncLifecycle {
    private struct InFlightDeletion {
        var version: VaultVersion
        var wasReobserved = false
    }

    /// CloudKit accepts at most 250 record changes in one network request.
    /// Every CKSyncEngine delegate in the app builds its batches through this lifecycle.
    nonisolated static let maximumRecordsPerRequest = 250

    let store: CloudSyncLifecycleStore
    let transport: CloudSyncTransport
    let zoneID: CKRecordZone.ID
    private let consumerIdentifier: String
    private let containerIdentifier: String
    private let defaults: UserDefaults
    private let enabledKey: String?
    private let defaultEnabled: Bool
    private let environmentKey: String
    private let environmentIdentifier: String
    private let authorizeUploads: (Bool) -> Void
    private let beforeSend: () throws -> Void
    private let receiveSnapshot: ([CKRecord], [CKRecord.ID]) throws -> Void
    private var inFlightDeletions: [String: InFlightDeletion] = [:]
    private var inventoryPending = false
    private var inventorySeen = Set<String>()
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
    var logger = ApplicationLogger.disabled("termind.cloud-sync")
    var terminalError: String?
    var status: VaultSyncStatus = .checkingAccount

    init(
        store: CloudSyncLifecycleStore, transport: CloudSyncTransport, zoneID: CKRecordZone.ID,
        containerIdentifier: String, defaults: UserDefaults, enabledKey: String?, defaultEnabled: Bool,
        environmentKey: String, environmentIdentifier: String, consumerIdentifier: String = "",
        authorizeUploads: @escaping (Bool) -> Void = { _ in }, beforeSend: @escaping () throws -> Void = {},
        receiveSnapshot: @escaping ([CKRecord], [CKRecord.ID]) throws -> Void = { _, _ in }
    ) {
        self.store = store
        self.transport = transport
        self.zoneID = zoneID
        self.consumerIdentifier = consumerIdentifier
        self.containerIdentifier = containerIdentifier
        self.defaults = defaults
        self.enabledKey = enabledKey
        self.defaultEnabled = defaultEnabled
        self.environmentKey = environmentKey
        self.environmentIdentifier = environmentIdentifier
        self.authorizeUploads = authorizeUploads
        self.beforeSend = beforeSend
        self.receiveSnapshot = receiveSnapshot
    }

    var isEnabled: Bool {
        (defaults.object(forKey: SettingsKey.iCloudSyncEnabled) as? Bool ?? SettingsKey.defaultICloudSyncEnabled)
            && (enabledKey.map { defaults.object(forKey: $0) as? Bool ?? defaultEnabled } ?? true)
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
        // Vault has no category switch: nil means it follows the master setting.
        guard let enabledKey else {
            start()
            return
        }
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
            try reconcilePendingChanges()
            guard isEnabled else { return }
            if engine == nil {
                start()
                return
            }
            run { [weak self] in
                try await self?.sendPendingChanges()
                try self?.updateUpToDateStatus()
            }
        } catch { failClosed(error) }
    }

    private func makeScope(account: String, environment: String) -> CloudSyncScope {
        var scope = CloudSyncScope(
            container: containerIdentifier, environment: environment, account: account,
            zone: zoneID.zoneName, owner: zoneID.ownerName)
        scope.consumer = consumerIdentifier
        return scope
    }

    func confirmAccountSwitchMerge() {
        guard isEnabled else { return }
        do {
            var state = try store.state()
            guard let pendingUser = state.pendingUserRecordName else { return }
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
        // Delegate callbacks can schedule follow-up sync work. A regular Task inherits
        // CloudKit's task-local callback context, making fetch/send trap even after
        // the callback returns. Detach that context while retaining MainActor isolation.
        operation = Task.detached { @MainActor @Sendable [weak self] in
            defer { if self?.operationID == id { self?.operation = nil } }
            do { try await body() } catch is CancellationError {} catch {
                guard let self, self.operationID == id else { return }
                if (error as? CKError)?.code == .changeTokenExpired {
                    self.restartAfterExpiredToken()
                } else if let cloudError = error as? CKError, Self.isRetryable(cloudError) {
                    self.logFailure(error, stage: "operation")
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
        try store.completePendingPurge()
        try store.save()
        let accountStatus = try await transport.accountStatus()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        guard accountStatus == .available else {
            status = status(for: accountStatus)
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
        self.scope = scope
        let requiresRefetch = try store.safety.prepare(scope)
        state.boundUserRecordName = currentUser
        state.pendingUserRecordName = nil
        try store.updateState(state)
        if defaults.string(forKey: environmentKey) != environmentIdentifier {
            try store.resetForEnvironment()
            try store.save()
            defaults.set(environmentIdentifier, forKey: environmentKey)
            terminalError = nil
        }
        let needsUpgrade = try store.replica?.prepare(scope) ?? false
        let serialized = try store.state().engineStateData
        let validSerialization = serialized.flatMap {
            try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
        }
        let needsSnapshot = requiresRefetch || needsUpgrade || validSerialization == nil
        inventoryPending = needsSnapshot && store.replica != nil
        inventorySeen.removeAll()
        if needsSnapshot {
            var fresh = try store.state()
            fresh.engineStateData = nil
            try store.updateState(fresh)
        }
        // Commit the recovery fence before constructing an automatically syncing engine.
        try setRecoveryRequired(true)
        let exists = try await transport.zoneExists()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        if !exists {
            try store.replica?.reset(scope)
            try store.resetForZone()
            try store.save()
        }
        try await transport.createZone()
        guard operationID == id, isStarted, isEnabled, !Task.isCancelled else { return }
        let engine = try transport.makeEngine(store.state().engineStateData)
        self.engine = engine
        try reconcilePendingChanges()
        try store.save()
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
    func reconcileRemoteChanges(
        records: [CKRecord], deletions: [CKRecord.ID]
    ) throws -> (records: [CKRecord], deletions: [CKRecord.ID]) {
        guard let scope, let replica = store.replica else { return (records, deletions) }
        let relevant = deletions.filter {
            $0.zoneID == zoneID && replica.handlesRecordName($0.recordName)
        }
        guard !relevant.isEmpty else { return (records, deletions) }
        let deletedNames = Set(relevant.map(\.recordName))
        let result = try replica.reconcileDeletions(scope, Array(deletedNames))
        if !result.recreated.isEmpty {
            try store.save()
            try reconcilePendingChanges()
        }
        let accepted = Set(result.deleted)
        return (
            records.filter {
                $0.recordID.zoneID != zoneID || !deletedNames.contains($0.recordID.recordName)
            },
            deletions.filter { $0.zoneID != zoneID || accepted.contains($0.recordName) }
        )
    }

    func noteRecordsObserved(_ records: [CKRecord], excluding deletions: [CKRecord.ID] = []) {
        let deletedNames = Set(
            deletions.filter { $0.zoneID == zoneID }.map { $0.recordName }
        )
        let names = records.filter {
            $0.recordID.zoneID == zoneID && !deletedNames.contains($0.recordID.recordName)
        }.map { $0.recordID.recordName }
        if inventoryPending { inventorySeen.formUnion(names) }
        for name in names where inFlightDeletions[name] != nil {
            inFlightDeletions[name]?.wasReobserved = true
        }
    }

    func beginFetch() throws {
        isReadyToSend = false
        authorizeUploads(false)
        if fetching == 0 { fetchFailed = false }
        fetching += 1
        try setRecoveryRequired(true)
    }

    func noteFetchFailure(_ error: CKError) {
        logFailure(error, stage: "fetch")
        fetchFailed = true
        isReadyToSend = false
        authorizeUploads(false)
        status = self.status(for: error)
    }

    func finishFetch(succeeded: Bool = true) throws {
        fetching = max(0, fetching - 1)
        fetchFailed = fetchFailed || !succeeded
        if fetching == 0 && !fetchFailed, let scope {
            if inventoryPending {
                let deleted = try store.replica?.missing(scope, inventorySeen).deleted ?? []
                try receiveSnapshot([], deleted.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
                try store.replica?.complete(scope)
                try store.save()
                inventoryPending = false
                inventorySeen.removeAll()
            }
            try store.safety.didCompleteFetch(scope)
        }
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
        if sending == 0 {
            // CKSyncEngine may finish or throw without an item result for every handed-off
            // delete. The durable journal remains authoritative; release unresolved slots
            // so a later send can retry them.
            inFlightDeletions.removeAll()
        }
        try setRecoveryRequired(!succeeded || fetching > 0 || sending > 0 || fetchFailed)
    }

    func reconcilePendingChanges() throws {
        guard let engine, let scope else { return }
        _ = try reconcilePendingChanges(engine: engine, scope: scope)
    }

    private func reconcilePendingChanges(
        engine: any CloudSyncEngineSession, scope: CloudSyncScope
    ) throws -> [String: CloudSyncMutation] {
        let mutations = try store.pendingChanges(scope)
        engine.reconcilePending(mutations, in: zoneID)
        return Dictionary(uniqueKeysWithValues: mutations.map { ($0.recordName, $0) })
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
        guard accepts(engine), isReadyToSend, let scope else { return nil }
        do {
            try setRecoveryRequired(true)
            let uploadable = try reconcilePendingChanges(engine: engine, scope: scope)
            var records: [CKRecord] = []
            var deletions: [CKRecord.ID] = []
            var included = Set<String>()
            for change in pending {
                let id: CKRecord.ID
                let operation: CloudSyncMutation.Operation
                switch change {
                case .saveRecord(let value):
                    id = value
                    operation = .save
                case .deleteRecord(let value):
                    id = value
                    operation = .delete
                @unknown default: continue
                }
                guard id.zoneID == zoneID, let mutation = uploadable[id.recordName],
                    mutation.operation == operation, try canUpload(id, engine: engine),
                    included.insert(id.recordName).inserted
                else { continue }
                // One result event can identify a delete only by record ID. Never hand off another
                // operation for that ID until the first result has released its causal slot.
                if inFlightDeletions[id.recordName] != nil { continue }
                if operation == .delete {
                    deletions.append(id)
                    inFlightDeletions[id.recordName] = InFlightDeletion(version: mutation.version)
                } else if let record = recordProvider(id) {
                    records.append(record)
                }
                if records.count + deletions.count == Self.maximumRecordsPerRequest { break }
            }
            guard accepts(engine), isReadyToSend, !records.isEmpty || !deletions.isEmpty else { return nil }
            for id in deletions {
                guard let deletion = inFlightDeletions[id.recordName] else { continue }
                try store.replica?.recordDeletionHandoff(
                    scope,
                    CloudSyncMutation(
                        recordName: id.recordName, operation: .delete, version: deletion.version))
            }
            // A delete must not leave this process before its causal incarnation is durable.
            try store.save()
            return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: records, recordIDsToDelete: deletions)
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
            status = .signInRequired
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
        // Retired operations can finish after a preference/account transition.
        // Cancellation must not replace the new engine's status with a red failure.
        guard !Self.isCancellation(error) else { return }
        logFailure(error, stage: "lifecycle")
        store.rollback()
        retireEngine()
        status = self.status(for: error)
    }

    /// Error userInfo can contain full CKRecords (including host data). Log stable
    /// domain/code and stage only; quarantine owns raw records for safe recovery.
    func logFailure(_ error: any Error, stage: String) {
        guard !Self.isCancellation(error) else { return }
        let value = error as NSError
        logger.error(
            "cloud.sync.failed",
            metadata: [
                "zone": .string(zoneID.zoneName), "stage": .string(stage),
                "error-domain": .string(value.domain), "error-code": .string(String(value.code)),
            ])
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
        inFlightDeletions.removeAll()
        inventoryPending = false
        inventorySeen.removeAll()
        let activeEngine = engine
        engine = nil
        // Account changes and failures can retire an engine from its delegate, too.
        if let activeEngine { Task.detached { @MainActor @Sendable in await activeEngine.cancel() } }
    }

    func handleZoneDeletion() throws {
        if let scope { try store.replica?.reset(scope) }
        try store.resetForZone()
        engine?.recreateZone(zoneID)
        try reconcilePendingChanges()
        try store.save()
    }

    func handleZoneDeletion(reason: CloudSyncZoneDeletionReason) throws {
        switch reason {
        case .deleted:
            try handleZoneDeletion()
        case .purged, .encryptedDataReset:
            guard let scope else { throw CancellationError() }
            // Retire before touching persistence so automatic callbacks cannot repopulate
            // a cache that the account owner explicitly removed.
            retireEngine()
            do {
                try store.purge(scope)
                status = .upToDate(lastSuccessfulSync: nil)
            } catch {
                store.rollback()
                throw error
            }
        }
    }

    func cancelDeletionHandoff(_ mutation: CloudSyncMutation) throws {
        guard let scope else { return }
        try store.replica?.cancelDeletionHandoff(scope, mutation)
    }

    func restartAfterExpiredToken() {
        failClosed(CKError(.changeTokenExpired))
        start()
    }

    func takeDeletionAcknowledgement(_ id: CKRecord.ID) -> CloudSyncMutation? {
        guard id.zoneID == zoneID, let deletion = inFlightDeletions.removeValue(forKey: id.recordName) else {
            return nil
        }
        // The result completes only the handed-off delete. If the record was observed again
        // afterward, the durable journal must remain pending for a new physical delete.
        guard !deletion.wasReobserved else { return nil }
        return CloudSyncMutation(recordName: id.recordName, operation: .delete, version: deletion.version)
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

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? CKError)?.code == .operationCancelled
    }

    func status(for error: any Error) -> VaultSyncStatus {
        if Self.isCancellation(error) { return status }
        if let cloudError = error as? CKError {
            if cloudError.code == .notAuthenticated { return .signInRequired }
            if Self.isRetryable(cloudError) { return .syncing(pendingCount: 0) }
        }
        return .failed(error.localizedDescription)
    }

    private func status(for accountStatus: CKAccountStatus) -> VaultSyncStatus {
        switch accountStatus {
        case .noAccount: .signInRequired
        case .restricted: .unavailable(String(localized: "iCloud access is restricted on this Mac."))
        case .couldNotDetermine: .unavailable(String(localized: "The iCloud account could not be checked."))
        case .temporarilyUnavailable: .unavailable(String(localized: "iCloud is temporarily unavailable."))
        case .available: .checkingAccount
        @unknown default: .unavailable(String(localized: "iCloud is unavailable."))
        }
    }
}

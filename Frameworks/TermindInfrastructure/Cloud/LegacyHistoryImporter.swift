import CloudKit
import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

/// One-way compatibility reader for pre-V35 TestFlight clients. This engine has
/// its own subscription/checkpoint and can NEVER supply a record change batch.
/// In particular, enabling History while Vault is off must not start Vault writes.
@MainActor
@Observable
final class LegacyHistoryImporter: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    static let subscriptionID = "termind-history-legacy-vault-v1-changes"
    private let includesHistory: () -> Bool
    private let context: ModelContext
    private let persistence: HistorySyncPersistence
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let zoneID = CKRecordZone.ID(zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
    private(set) var engine: (any CloudSyncEngineSession)?
    private(set) var scope: CloudSyncScope?
    private var generation = UUID()
    @ObservationIgnored private var readinessWaiter: CheckedContinuation<Void, any Error>?
    private var fetching = 0
    private var fetchFailed = false
    private(set) var isReady = false
    var logFailure: ((any Error) -> Void)?
    var didChangeAccount: ((CKSyncEngine.Event.AccountChange.ChangeType) -> Void)?
    var didApply: ((Set<HistoryRecordKey>) -> Void)?
    var didFinish: (() -> Void)?
    var didFail: (((any Error)) -> Void)?

    init(
        context: ModelContext, includesHistory: @escaping () -> Bool = { true },
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        self.includesHistory = includesHistory
        self.context = context
        persistence = HistorySyncPersistence(context: context)
        self.makeTransport = makeTransport
        super.init()
    }

    func prepare(destinationScope: CloudSyncScope) async throws {
        stop()
        let generation = generation
        let sourceScope = destinationScope.historyImportScope
        scope = sourceScope
        let state = try CloudSyncSafetyStore(context: context, scope: sourceScope).historyImportState()
        let capability = capabilityID
        let serialization = state.requiresRefetch || state.capabilityID != capability ? nil : state.engineStateData
        // Persist the replay fence before constructing an automatically syncing engine.
        state.requiresRefetch = true
        try context.save()
        let transport = makeTransport(zoneID, self)
        let account = try await transport.userRecordName()
        guard self.generation == generation, account == sourceScope.account, !Task.isCancelled else {
            throw CancellationError()
        }
        let engine = try transport.makeEngine(serialization)
        self.engine = engine
        try beginFetch()
        do {
            // Never create the legacy zone: a new installation may not have one.
            try await engine.fetch(in: zoneID)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // No legacy data is a successful empty source, not a reason to recreate it.
        } catch {
            if accepts(engine) { try finishFetch(succeeded: false) }
            throw error
        }
        guard accepts(engine), self.generation == generation, !Task.isCancelled else { throw CancellationError() }
        try finishFetch(succeeded: true)
        // The explicit fetch can return before overlapping automatic fetch events
        // finish. Await their committed checkpoint instead of inventing a database
        // error or opening the upload gate while the source is still being read.
        if !isReady {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    readinessWaiter = continuation
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.stop()
                }
            }
        }
        guard accepts(engine), self.generation == generation, !Task.isCancelled else { throw CancellationError() }
    }

    private var capabilityID: String {
        SyncRecordFormats.history.capabilityID + (includesHistory() ? ";events:on" : ";events:off")
    }

    func stop() {
        let waiter = readinessWaiter
        readinessWaiter = nil
        waiter?.resume(throwing: CancellationError())
        generation = UUID()
        isReady = false
        fetching = 0
        fetchFailed = false
        scope = nil
        let previous = engine
        engine = nil
        if let previous { Task { await previous.cancel() } }
    }
    func ready(for destinationScope: CloudSyncScope) -> Bool {
        isReady && scope == destinationScope.historyImportScope
    }
    private func accepts(_ engine: any CloudSyncEngineSession) -> Bool { self.engine === engine }

    public nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(
            scope: .zoneIDs([
                CKRecordZone.ID(zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)
            ]))
    }
    public nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        // Intentional read-only exception to the writer lifecycle. Even a restored
        // serialization containing saves/deletes cannot emit them through this delegate.
        nil
    }
    public nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await handle(event, engine: syncEngine)
    }
    private func handle(_ event: CKSyncEngine.Event, engine: CKSyncEngine) {
        guard accepts(engine), let scope else { return }
        do {
            switch event {
            case .stateUpdate(let update):
                try CloudSyncSafetyStore(context: context, scope: scope).historyImportState().engineStateData =
                    JSONEncoder().encode(update.stateSerialization)
                try context.save()
            case .willFetchChanges: try beginFetch()
            case .fetchedRecordZoneChanges(let changes):
                try receive(changes.modifications.map(\.record))
            // Physical console deletions are not protocol tombstones. Do not delete
            // destination history and never recreate a record in the legacy zone.
            case .didFetchRecordZoneChanges(let changes):
                if let error = changes.error, error.code != .zoneNotFound && error.code != .userDeletedZone {
                    fetchFailed = true
                    throw error
                }
            case .didFetchChanges: try finishFetch(succeeded: true)
            case .accountChange(let change):
                handleAccountChange(change.changeType)
            default: break
            }
        } catch {
            context.rollback()
            stop()
            didFail?(error)
        }
    }

    func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange.ChangeType) {
        // A newly constructed CKSyncEngine can announce the account we already
        // checked. That is normal startup, not a cancelled or failed import.
        if case .signIn(let user) = change, user.recordName == scope?.account { return }
        stop()
        didChangeAccount?(change)
    }

    func receive(_ records: [CKRecord]) throws {
        guard let scope else { throw CancellationError() }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        var decoded: [HistoryEnvelope] = []
        var rejected = Set<String>()
        // A separate record type in the legacy zone is not part of the Vault V1
        // history stream. Do not quarantine unrelated future features.
        for record in records
        where record.recordID.zoneID == zoneID && record.recordType == VaultSyncCoordinator.recordType {
            if let key = VaultRecordKey(recordName: record.recordID.recordName), key.kind.isConfiguration { continue }
            if let key = HistoryRecordKey(recordName: record.recordID.recordName),
                key.kind == .connectionHistory && !includesHistory()
            {
                continue
            }
            do {
                let legacy = try VaultSyncCoordinator.envelope(from: record)
                guard let envelope = HistoryEnvelope(legacy: legacy) else {
                    throw VaultSyncPersistenceError.invalidEnvelope(record.recordID.recordName)
                }
                decoded.append(envelope)
            } catch {
                logFailure?(error)
                try CloudSyncRecordCoding.quarantine(record, error: error, in: safety)
                rejected.insert(record.recordID.recordName)
            }
        }
        decoded.removeAll { rejected.contains($0.key.recordName) }
        let changed = try persistence.applyRemote(decoded, importingLegacy: true) {
            for envelope in decoded { try safety.clearQuarantine(recordName: envelope.key.recordName) }
        }
        if !changed.isEmpty { didApply?(changed) }
    }

    func beginFetch() throws {
        guard let scope else { throw CancellationError() }
        isReady = false
        if fetching == 0 { fetchFailed = false }
        fetching += 1
        try CloudSyncSafetyStore(context: context, scope: scope).historyImportState().requiresRefetch = true
        try context.save()
    }
    func finishFetch(succeeded: Bool) throws {
        guard let scope else { throw CancellationError() }
        fetching = max(0, fetching - 1)
        fetchFailed = fetchFailed || !succeeded
        let state = try CloudSyncSafetyStore(context: context, scope: scope).historyImportState()
        let complete = fetching == 0 && !fetchFailed
        state.requiresRefetch = !complete
        if complete { state.capabilityID = capabilityID }
        try context.save()
        isReady = complete
        if complete {
            let waiter = readinessWaiter
            readinessWaiter = nil
            waiter?.resume()
            didFinish?()
        }
    }
}

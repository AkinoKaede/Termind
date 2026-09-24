import CloudKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncLifecycleTests {
    @Test
    func sharedEventDispatcherRoutesCallbacksAndRejectsRetiredEngines() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let activeEngine = fixture.network.nextEngine
        let record = CKRecord(
            recordType: "Test",
            recordID: CKRecord.ID(recordName: "remote", zoneID: fixture.driver.zoneID))
        var receivedRecordNames: [String] = []
        var sentCallbackCount = 0
        let receive: @MainActor @Sendable ([CKRecord], [CKRecord.ID]) throws -> Void = {
            receivedRecordNames.append(contentsOf: $0.map(\.recordID.recordName))
            #expect($1.isEmpty)
        }
        let sent: @MainActor @Sendable (CloudSyncSentChanges) throws -> Void = { _ in sentCallbackCount += 1 }

        fixture.driver.handle(
            .fetchedRecordZoneChanges(records: [record], deletions: []), engine: activeEngine,
            receiveRemoteRecords: receive, handleSentChanges: sent)
        fixture.driver.handle(
            .sentRecordZoneChanges(.init(savedRecords: [], failedRecordSaves: [])), engine: activeEngine,
            receiveRemoteRecords: receive, handleSentChanges: sent)
        fixture.driver.handle(
            .fetchedDatabaseChanges(deletedZoneIDs: [fixture.driver.zoneID]), engine: activeEngine,
            receiveRemoteRecords: receive, handleSentChanges: sent)

        #expect(receivedRecordNames == ["remote"])
        #expect(sentCallbackCount == 1)
        #expect(fixture.journal.resets == ["environment", "zone"])

        fixture.driver.pause()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.driver.start()
        await fixture.driver.operation?.value
        fixture.driver.handle(
            .fetchedRecordZoneChanges(records: [record], deletions: []), engine: activeEngine,
            receiveRemoteRecords: receive, handleSentChanges: sent)
        #expect(receivedRecordNames == ["remote"])
    }

    @Test
    func sharedEventDispatcherFailsClosedAndFetchFailureKeepsUploadsFenced() async {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let engine = fixture.network.nextEngine
        let unusedReceive: @MainActor @Sendable ([CKRecord], [CKRecord.ID]) throws -> Void = { _, _ in }
        let unusedSent: @MainActor @Sendable (CloudSyncSentChanges) throws -> Void = { _ in }

        fixture.driver.handle(
            .willFetchChanges, engine: engine, receiveRemoteRecords: unusedReceive,
            handleSentChanges: unusedSent)
        fixture.driver.handle(
            .didFetchRecordZoneChanges(CKError(.networkFailure)), engine: engine,
            receiveRemoteRecords: unusedReceive, handleSentChanges: unusedSent)
        fixture.driver.handle(
            .didFetchChanges, engine: engine, receiveRemoteRecords: unusedReceive,
            handleSentChanges: unusedSent)
        #expect(fixture.driver.accepts(engine))
        #expect(!fixture.driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.recoveryRequired)

        let record = CKRecord(recordType: "Test")
        fixture.driver.handle(
            .fetchedRecordZoneChanges(records: [record], deletions: []), engine: engine,
            receiveRemoteRecords: { _, _ in throw CocoaError(.fileWriteUnknown) },
            handleSentChanges: unusedSent)
        #expect(fixture.driver.engine == nil)
        #expect(!fixture.journal.uploadsAuthorized)
        guard case .failed = fixture.driver.status else {
            Issue.record("A category callback failure must fail the shared dispatcher closed")
            return
        }
    }

    @Test
    func sharedFailedSaveHandlerPreservesConflictZoneRetryAndTerminalSemantics() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let serverRecord = CKRecord(recordType: "Test")
        var conflictRecord: CKRecord?
        try fixture.driver.handleFailedSave(
            CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: serverRecord])
        ) { records, isConflict in
            conflictRecord = records.first
            #expect(isConflict)
        }
        #expect(conflictRecord === serverRecord)
        #expect(throws: CKError.self) {
            try fixture.driver.handleFailedSave(CKError(.serverRecordChanged)) { _, _ in }
        }

        try fixture.driver.handleFailedSave(CKError(.zoneNotFound)) { _, _ in }
        #expect(fixture.journal.resets == ["environment", "zone"])
        try fixture.driver.handleFailedSave(CKError(.networkFailure)) { _, _ in }
        #expect(fixture.driver.terminalError == nil)
        try fixture.driver.handleFailedSave(CKError(.permissionFailure)) { _, _ in }
        #expect(fixture.driver.terminalError != nil)
        guard case .failed = fixture.driver.status else {
            Issue.record("A terminal save error must remain visible")
            return
        }
    }

    @Test
    func uploadBatchesNeverExceedCloudKitRequestLimit() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let ids = (0..<505).map {
            CKRecord.ID(recordName: "record-\($0)", zoneID: fixture.driver.zoneID)
        }
        let pending = ids.map(CKSyncEngine.PendingRecordZoneChange.saveRecord)

        let first = try #require(
            fixture.driver.makeChangeBatch(pending, engine: fixture.network.nextEngine) {
                CKRecord(recordType: "Test", recordID: $0)
            })
        let second = try #require(
            fixture.driver.makeChangeBatch(Array(pending.dropFirst(250)), engine: fixture.network.nextEngine) {
                CKRecord(recordType: "Test", recordID: $0)
            })
        let third = try #require(
            fixture.driver.makeChangeBatch(Array(pending.dropFirst(500)), engine: fixture.network.nextEngine) {
                CKRecord(recordType: "Test", recordID: $0)
            })

        #expect(CloudSyncLifecycle.maximumRecordsPerRequest == 250)
        #expect(first.recordsToSave.map(\.recordID) == Array(ids.prefix(250)))
        #expect(second.recordsToSave.map(\.recordID) == Array(ids.dropFirst(250).prefix(250)))
        #expect(third.recordsToSave.map(\.recordID) == Array(ids.suffix(5)))
        #expect(first.recordIDsToDelete.isEmpty)
    }

    @Test
    func invalidPendingChangesDoNotConsumeTheRequestLimit() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let ids = (0..<280).map {
            CKRecord.ID(recordName: "record-\($0)", zoneID: fixture.driver.zoneID)
        }
        fixture.journal.blocked = Set(ids.prefix(10).map(\.recordName))
        let missing = Set(ids.dropFirst(10).prefix(10).map(\.recordName))
        let pending = ids.flatMap {
            [
                CKSyncEngine.PendingRecordZoneChange.deleteRecord($0),
                CKSyncEngine.PendingRecordZoneChange.saveRecord($0),
            ]
        }

        let batch = try #require(
            fixture.driver.makeChangeBatch(pending, engine: fixture.network.nextEngine) { id in
                missing.contains(id.recordName) ? nil : CKRecord(recordType: "Test", recordID: id)
            })

        #expect(batch.recordsToSave.count == 250)
        #expect(batch.recordsToSave.first?.recordID == ids[20])
        #expect(batch.recordsToSave.last?.recordID == ids[269])
        #expect(batch.recordIDsToDelete.isEmpty)
    }

    @Test
    func firstFetchGatesSendsAndAuthorizationWhileLocalChangesAccumulate() async throws {
        let fixture = LifecycleFixture()
        let gate = LifecycleGate()
        fixture.network.nextEngine.fetchBody = { try await gate.suspend() }
        let driver = fixture.driver
        driver.start()
        driver.start()
        await gate.waitUntilEntered()
        #expect(fixture.network.engineCount == 1)
        #expect(!driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        fixture.journal.pending.append("second")
        driver.noteLocalChanges(["second"])
        #expect(fixture.network.nextEngine.sendCount == 0)
        gate.resume()
        await driver.operation?.value
        #expect(driver.isReadyToSend)
        #expect(fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.migrationCount == 1)
        #expect(fixture.network.nextEngine.sendCount == 1)
        #expect(Set(fixture.network.nextEngine.queued) == ["first", "second"])
        #expect(fixture.network.steps == ["account", "user", "engine", "zone"])
    }

    @Test
    func failedFetchCannotAuthorizeOrSendAndRetryUsesTheSameEngine() async {
        let fixture = LifecycleFixture()
        fixture.network.nextEngine.fetchBody = { throw CKError(.networkFailure) }
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(!fixture.driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.migrationCount == 0)
        #expect(fixture.network.nextEngine.sendCount == 0)
        #expect(fixture.driver.status == .syncing(pendingCount: 0))
        fixture.network.nextEngine.fetchBody = {}
        fixture.driver.retry()
        await fixture.driver.operation?.value
        #expect(fixture.network.engineCount == 1)
        #expect(fixture.network.nextEngine.sendCount == 1)
        #expect(fixture.journal.uploadsAuthorized)
        fixture.driver.pause()
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(!fixture.driver.isReadyToSend)
    }

    @Test
    func retiredAccountFailureCannotOverwriteOrClearTheReplacementOperation() async throws {
        let fixture = LifecycleFixture()
        let account = LifecycleGate()
        fixture.network.accountBody = {
            try await account.suspend()
            return .available
        }
        fixture.driver.start()
        await account.waitUntilEntered()
        let retiredOperation = fixture.driver.operation
        fixture.driver.pause()
        let fetch = LifecycleGate()
        fixture.network.accountBody = { .available }
        fixture.network.nextEngine.fetchBody = { try await fetch.suspend() }
        fixture.driver.start()
        await fetch.waitUntilEntered()
        account.resume(throwing: CKError(.permissionFailure))
        await retiredOperation?.value
        #expect(fixture.driver.operation != nil)
        #expect(fixture.driver.status == .checkingAccount)
        #expect(!fixture.journal.uploadsAuthorized)
        fetch.resume()
        await fixture.driver.operation?.value
        #expect(fixture.driver.status == .syncing(pendingCount: 1))
    }

    @Test(arguments: [false, true])
    func retiringAnEngineDuringFetchOrSendRejectsItsLateCompletion(duringSend: Bool) async {
        let fixture = LifecycleFixture()
        let gate = LifecycleGate()
        let retiredEngine = fixture.network.nextEngine
        if duringSend {
            retiredEngine.sendBody = { try await gate.suspend() }
        } else {
            retiredEngine.fetchBody = { try await gate.suspend() }
        }
        fixture.driver.start()
        await gate.waitUntilEntered()
        let retiredOperation = fixture.driver.operation
        fixture.driver.pause()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.journal.pending = []
        fixture.driver.start()
        await fixture.driver.operation?.value
        let replacementStatus = fixture.driver.status
        #expect(!fixture.driver.accepts(retiredEngine))
        gate.resume()
        await retiredOperation?.value
        #expect(fixture.driver.status == replacementStatus)
        #expect(retiredEngine.sendCount == (duringSend ? 1 : 0))
        #expect(fixture.network.nextEngine.fetchCount == 1)
    }

    @Test
    func differentAccountRequiresConfirmationAndResetsBeforeBinding() async throws {
        let fixture = LifecycleFixture()
        fixture.journal.value.boundUserRecordName = "old-user"
        fixture.journal.value.engineStateData = Data([1])
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.driver.status == .accountChangeConfirmationRequired)
        #expect(fixture.journal.value.boundUserRecordName == "old-user")
        #expect(fixture.journal.value.pendingUserRecordName == "current-user")
        #expect(fixture.network.engineCount == 0)
        #expect(!fixture.journal.uploadsAuthorized)
        fixture.driver.confirmAccountSwitchMerge()
        await fixture.driver.operation?.value
        #expect(fixture.journal.resets == ["account", "environment"])
        #expect(fixture.journal.value.boundUserRecordName == "current-user")
        #expect(fixture.journal.value.pendingUserRecordName == nil)
        #expect(fixture.network.serializations.count == 1)
        #expect(fixture.network.serializations[0] == nil)
    }

    @Test(arguments: ["signOut", "switchAccounts", "differentSignIn", "sameSignIn"])
    func accountEventsRetireOnlyWhenRequired(event: String) async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let engine = fixture.network.nextEngine
        let current = CKRecord.ID(recordName: "current-user")
        let other = CKRecord.ID(recordName: "other-user")
        let change: CKSyncEngine.Event.AccountChange.ChangeType =
            switch event {
            case "signOut": .signOut(previousUser: current)
            case "switchAccounts": .switchAccounts(previousUser: current, currentUser: other)
            case "differentSignIn": .signIn(currentUser: other)
            default: .signIn(currentUser: current)
            }
        try fixture.driver.handleAccountChange(change)
        #expect(fixture.driver.accepts(engine) == (event == "sameSignIn"))
        #expect(fixture.journal.uploadsAuthorized == (event == "sameSignIn"))
        if event == "switchAccounts" || event == "differentSignIn" {
            #expect(fixture.journal.value.pendingUserRecordName == "other-user")
            #expect(fixture.driver.status == .accountChangeConfirmationRequired)
        }
    }

    @Test
    func environmentAndZoneResetsRequeueRecordsWithoutDroppingAccountBinding() async throws {
        let fixture = LifecycleFixture()
        fixture.journal.value.engineStateData = Data([1, 2])
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.journal.resets == ["environment"])
        #expect(fixture.network.serializations[0] == nil)
        try fixture.driver.handleZoneDeletion()
        #expect(fixture.journal.resets == ["environment", "zone"])
        #expect(fixture.network.nextEngine.recreatedZones == [fixture.driver.zoneID])
        #expect(fixture.journal.value.boundUserRecordName == "current-user")
        fixture.driver.pause()
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.journal.resets == ["environment", "zone"])
    }

    @Test
    func quarantineAndTerminalErrorsPreventSuccessfulStatusWithoutBlockingOtherRecords() async throws {
        let fixture = LifecycleFixture()
        fixture.journal.blocked = ["first", "unsupported"]
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.driver.status == .partiallyBlocked(pendingCount: 0, blockedCount: 2))
        #expect(fixture.network.nextEngine.sendCount == 0)
        fixture.driver.terminalError = "terminal"
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.driver.status == .failed("terminal"))
        #expect(fixture.journal.value.lastSuccessfulSync == nil)
        fixture.driver.terminalError = nil
        fixture.journal.pending = []
        fixture.journal.blocked = []
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.journal.value.lastSuccessfulSync != nil)
        #expect(fixture.driver.status == .upToDate(lastSuccessfulSync: fixture.journal.value.lastSuccessfulSync))
    }

    @Test
    func persistedRecoveryFenceDiscardsTheCursorButPreservesPendingChanges() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        fixture.driver.pause()
        fixture.journal.value.engineStateData = Data([7, 8])
        fixture.journal.recoveryRequired = true
        fixture.network.nextEngine = LifecycleEngine()
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.network.serializations.last! == nil)
        #expect(fixture.network.nextEngine.queued.contains("first"))
        #expect(!fixture.journal.recoveryRequired)
    }

    @Test
    func delegateFailureDuringFetchCannotBeOverwrittenBySuccessfulFetchCompletion() async {
        let fixture = LifecycleFixture()
        fixture.network.nextEngine.fetchBody = {
            fixture.driver.failClosed(CocoaError(.fileWriteUnknown))
        }
        fixture.driver.start()
        let operation = fixture.driver.operation
        await operation?.value
        #expect(fixture.driver.engine == nil)
        #expect(!fixture.driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.recoveryRequired)
        #expect(fixture.network.nextEngine.sendCount == 0)
        guard case .failed = fixture.driver.status else {
            Issue.record("A successful fetch callback must not erase a persistence failure")
            return
        }
        fixture.network.nextEngine = LifecycleEngine()
        fixture.driver.retry()
        await fixture.driver.operation?.value
        #expect(fixture.network.serializations.last! == nil)
        #expect(fixture.driver.isReadyToSend)
    }

    @Test
    func failedFenceSavePreventsNetworkAndLookupFailureInvalidatesAReadyEngine() async {
        let fixture = LifecycleFixture()
        fixture.journal.saveError = CocoaError(.fileWriteUnknown)
        fixture.driver.start()
        await fixture.driver.operation?.value
        #expect(fixture.network.engineCount == 0)
        #expect(!fixture.driver.isReadyToSend)
        fixture.journal.saveError = nil
        fixture.driver.retry()
        await fixture.driver.operation?.value
        let engine = fixture.network.nextEngine
        fixture.journal.lookupError = CocoaError(.fileReadUnknown)
        fixture.driver.noteLocalChanges(["first"])
        #expect(!fixture.driver.accepts(engine))
        #expect(!fixture.journal.uploadsAuthorized)
    }

    @Test
    func overlappingExplicitCallsAndAutomaticEventsKeepRecoveryUntilBothComplete() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        try fixture.driver.beginFetch()
        try fixture.driver.beginFetch()
        try fixture.driver.finishFetch()
        #expect(!fixture.driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.recoveryRequired)
        try fixture.driver.beginSend()
        try fixture.driver.finishFetch()
        #expect(fixture.driver.isReadyToSend)
        #expect(fixture.journal.recoveryRequired)
        try fixture.driver.finishSend()
        #expect(!fixture.journal.recoveryRequired)
    }

    @Test
    func retryableZoneFailureKeepsAutomaticEngineButClosesUploadsUntilNextSuccessfulFetch() async throws {
        let fixture = LifecycleFixture()
        fixture.driver.start()
        await fixture.driver.operation?.value
        let engine = fixture.network.nextEngine
        try fixture.driver.beginFetch()
        fixture.driver.noteFetchFailure(CKError(.networkFailure))
        try fixture.driver.finishFetch()
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.driver.accepts(engine))
        #expect(!fixture.driver.isReadyToSend)
        #expect(!fixture.journal.uploadsAuthorized)
        #expect(fixture.journal.recoveryRequired)
        #expect(fixture.driver.status == .syncing(pendingCount: 0))
        try fixture.driver.beginFetch()
        try fixture.driver.finishFetch()
        #expect(fixture.driver.isReadyToSend)
        #expect(fixture.journal.uploadsAuthorized)
        #expect(!fixture.journal.recoveryRequired)
    }

    @Test
    func disabledCategoryNeverStartsOrConfirmsAnAccountSwitch() async {
        let fixture = LifecycleFixture()
        fixture.driver.setEnabled(false)
        fixture.journal.value.pendingUserRecordName = "other-user"
        fixture.driver.start()
        fixture.driver.retry()
        fixture.driver.confirmAccountSwitchMerge()
        #expect(fixture.driver.status == .paused)
        #expect(fixture.driver.operation == nil)
        #expect(fixture.network.steps.isEmpty)
        #expect(fixture.journal.resets.isEmpty)
    }
}

@MainActor
private struct LifecycleFixture {
    let journal = LifecycleJournal()
    let network = LifecycleNetwork()
    let driver: CloudSyncLifecycle

    init() {
        let journal = journal
        let network = network
        driver = CloudSyncLifecycle(
            store: CloudSyncLifecycleStore(
                state: { journal.value }, updateState: { journal.value = $0 },
                save: { if let error = journal.saveError { throw error } }, rollback: {},
                pendingRecordNames: { _ in journal.pending.filter { !journal.blocked.contains($0) } },
                safety: CloudSyncLifecycleSafety(
                    prepare: { _, _ in journal.recoveryRequired },
                    setRecoveryRequired: { _, value in journal.recoveryRequired = value },
                    blockedRecordNames: { _ in
                        if let error = journal.lookupError { throw error }
                        return journal.blocked
                    },
                    isUploadBlocked: { _, recordName in
                        if let error = journal.lookupError { throw error }
                        return journal.blocked.contains(recordName)
                    },
                    requiresNewerClient: { _ in false }),
                resetForNewAccount: { journal.reset("account") },
                resetForZone: { journal.reset("zone") },
                resetForEnvironment: { journal.reset("environment") }),
            transport: network.transport, zoneID: .init(zoneName: "LifecycleTests"),
            containerIdentifier: "LifecycleTests",
            defaults: UserDefaults(suiteName: "CloudSyncLifecycleTests.\(UUID())")!,
            enabledKey: "enabled", defaultEnabled: true, environmentKey: "environment",
            environmentIdentifier: "Development", signInMessage: { "Sign in" },
            authorizeUploads: { journal.uploadsAuthorized = $0 },
            beforeSend: { journal.migrationCount += 1 })
    }
}

@MainActor
private final class LifecycleJournal {
    var value = CloudSyncState()
    var pending = ["first"]
    var blocked = Set<String>()
    var recoveryRequired = false
    var saveError: (any Error)?
    var lookupError: (any Error)?
    var resets: [String] = []
    var uploadsAuthorized = false
    var migrationCount = 0
    func reset(_ reason: String) {
        resets.append(reason)
        value.engineStateData = nil
    }
}

@MainActor
final class LifecycleNetwork {
    var steps: [String] = []
    var serializations: [Data?] = []
    var engineCount = 0
    var nextEngine = LifecycleEngine()
    var accountBody: () async throws -> CKAccountStatus = { .available }
    var transport: CloudSyncTransport {
        CloudSyncTransport(
            accountStatus: {
                self.steps.append("account")
                return try await self.accountBody()
            },
            userRecordName: {
                self.steps.append("user")
                return "current-user"
            },
            createZone: { self.steps.append("zone") },
            makeEngine: {
                self.steps.append("engine")
                self.serializations.append($0)
                self.engineCount += 1
                return self.nextEngine
            })
    }
}

@MainActor
final class LifecycleEngine: CloudSyncEngineSession {
    var queued: [String] = []
    var recreatedZones: [CKRecordZone.ID] = []
    var fetchCount = 0
    var sendCount = 0
    var cancelCount = 0
    var fetchBody: () async throws -> Void = {}
    var sendBody: () async throws -> Void = {}
    func fetch(in zoneID: CKRecordZone.ID) async throws {
        fetchCount += 1
        try await fetchBody()
    }
    func send() async throws {
        sendCount += 1
        try await sendBody()
    }
    func cancel() async { cancelCount += 1 }
    func enqueue(_ recordNames: [String], in zoneID: CKRecordZone.ID) { queued.append(contentsOf: recordNames) }
    func removePending(_ recordNames: Set<String>, in zoneID: CKRecordZone.ID) {
        queued.removeAll { recordNames.contains($0) }
    }
    func recreateZone(_ zoneID: CKRecordZone.ID) { recreatedZones.append(zoneID) }
}

@MainActor
private final class LifecycleGate {
    private var continuation: CheckedContinuation<Void, any Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    func suspend() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            arrival?.resume()
            arrival = nil
        }
    }
    func waitUntilEntered() async {
        if continuation != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func resume(throwing error: (any Error)? = nil) {
        if let error { continuation?.resume(throwing: error) } else { continuation?.resume() }
        continuation = nil
    }
}

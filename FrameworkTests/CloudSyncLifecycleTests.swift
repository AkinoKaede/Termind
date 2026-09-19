import CloudKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncLifecycleTests {
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
    func quarantineAndTerminalErrorsTakePrecedenceOverSuccessfulStatus() throws {
        let fixture = LifecycleFixture()
        fixture.journal.pending = []
        fixture.journal.quarantine = "quarantined"
        fixture.driver.terminalError = "terminal"
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.driver.status == .failed("quarantined"))
        fixture.journal.quarantine = nil
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.driver.status == .failed("terminal"))
        #expect(fixture.journal.value.lastSuccessfulSync == nil)
        fixture.driver.terminalError = nil
        try fixture.driver.updateUpToDateStatus()
        #expect(fixture.journal.value.lastSuccessfulSync != nil)
        #expect(fixture.driver.status == .upToDate(lastSuccessfulSync: fixture.journal.value.lastSuccessfulSync))
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
                save: {}, rollback: {}, pendingRecordNames: { journal.pending },
                quarantineReason: { journal.quarantine },
                resetForNewAccount: { journal.reset("account") },
                resetForZone: { journal.reset("zone") },
                resetForEnvironment: { journal.reset("environment") }),
            transport: network.transport, zoneID: .init(zoneName: "LifecycleTests"),
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
    var quarantine: String?
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

import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindRemoteInfrastructure

@Suite @MainActor
struct TailscaleProfileCleanupTests {
    @Test func deletingAnInactiveProfileWithoutProErasesOnlyItsOwnState() async throws {
        let first = try group("first.ts.net")
        let second = try group("second.ts.net")
        let library = HostLibraryModel(groups: [first, second])
        let store = InMemoryTailscaleLocalStore()
        let ids = [UUID(), UUID()]
        try store.save(.init(groupID: first.id, profileID: ids[0]))
        try store.save(.init(groupID: second.id, profileID: ids[1]))
        let probe = CleanupProbe(network: try #require(first.tailscale?.network))
        let model = probe.model(library, store: store, access: false)
        model.start()
        library.replacePersistedSnapshot(VaultSnapshot(groups: [second]))
        #expect(await settles { probe.erased == [ids[0]] })
        #expect(probe.created.isEmpty)
        #expect(try store.load().map(\.profileID) == [ids[1]])
        #expect(try store.pendingCleanupProfiles().isEmpty)
        await model.shutdown()
    }

    @Test func failedErasureSurvivesDatabaseReopeningAndRetriesWithoutStartingANode() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Cleanup.store")
        let group = try group("example.ts.net")
        let profileID = UUID()
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        probe.failErase = true
        try await seedAndFailCleanup(url, group: group, profileID: profileID, probe: probe)
        probe.failErase = false
        let container = try TermindPersistence.makeContainer(url: url)
        let store = SwiftDataTailscaleLocalStore(context: container.mainContext)
        #expect(try store.load().isEmpty)
        #expect(try store.pendingCleanupProfiles() == [profileID])
        let model = probe.model(HostLibraryModel(), store: store, access: false)
        model.start()
        #expect(await settles { probe.erased == [profileID] })
        #expect(try store.pendingCleanupProfiles().isEmpty)
        #expect(probe.created.isEmpty)
        await model.shutdown()
    }

    private func seedAndFailCleanup(
        _ url: URL, group: HostGroup, profileID: UUID, probe: CleanupProbe
    ) async throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let store = SwiftDataTailscaleLocalStore(context: container.mainContext)
        try store.save(.init(groupID: group.id, profileID: profileID))
        let model = probe.model(HostLibraryModel(), store: store, access: false)
        model.start()
        #expect(await settles { model.error != nil })
        #expect(try store.pendingCleanupProfiles() == [profileID])
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func deletingWhileFactoryIsSuspendedWaitsForTheLateNodeToClose(shutdown: Bool) async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let store = InMemoryTailscaleLocalStore()
        let profileID = UUID()
        try store.save(.init(groupID: group.id, profileID: profileID))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        probe.holdFactory = true
        let model = probe.model(library, store: store)
        model.start()
        #expect(await settles { probe.factoryContinuation != nil })
        library.replacePersistedSnapshot(VaultSnapshot())
        for _ in 0..<20 { await Task.yield() }
        #expect(probe.erased.isEmpty)
        #expect(try store.pendingCleanupProfiles() == [profileID])
        if shutdown { await model.shutdown() }
        probe.releaseFactory()
        #expect(await settles { probe.erased == [profileID] })
        #expect(probe.events == ["close:\(profileID)", "erase:\(profileID)"])
        await model.shutdown()
    }

    @Test(arguments: [false, true])
    func cancelledOrFailedLoginCleansItsCandidateWithoutTouchingAnExistingProfile(factoryFails: Bool) async throws {
        let group = try group("example.ts.net")
        let store = InMemoryTailscaleLocalStore()
        let retained = UUID()
        try store.save(.init(groupID: group.id, profileID: retained))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        probe.holdFactory = true
        probe.failFactory = factoryFails
        let model = probe.model(HostLibraryModel(groups: [group]), store: store)
        // Avoid starting the retained profile; beginLogin is also valid before start.
        model.beginLoginAndSave(
            name: group.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil)
        #expect(await settles { probe.factoryContinuation != nil })
        let candidate = try #require(probe.created.first)
        model.cancelLogin()
        probe.releaseFactory()
        #expect(await settles { probe.erased == [candidate] })
        #expect(try store.load().map(\.profileID) == [retained])
        #expect(!probe.erased.contains(retained))
        await model.shutdown()
    }

    @Test func reloginRetiresTheOldProfileButKeepsTheNewEnrollment() async throws {
        let group = try group("example.ts.net")
        let store = InMemoryTailscaleLocalStore()
        let old = UUID()
        try store.save(.init(groupID: group.id, profileID: old))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(HostLibraryModel(groups: [group]), store: store)
        model.start()
        #expect(await settles { model.runningGroups.contains(group.id) })
        model.beginLoginAndSave(
            name: group.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil,
            groupID: group.id)
        #expect(await settles { model.loginCompletedGroupID == group.id && probe.erased.contains(old) })
        let current = try #require(try store.load().first?.profileID)
        #expect(current != old)
        #expect(probe.erased == [old])
        #expect(probe.nodes[old]?.closed == true)
        #expect(probe.nodes[current]?.closed == false)
        #expect(try store.pendingCleanupProfiles().isEmpty)
        await model.shutdown()
    }

    @Test func multipleLoginsToTheSameTailnetKeepTheirProfilesAndDeletionIndependent() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel()
        let store = InMemoryTailscaleLocalStore()
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(library, store: store)
        model.start()
        for name in ["First", "Second"] {
            model.beginLoginAndSave(
                name: name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil)
            #expect(await settles { model.loginCompletedGroupID != nil })
        }
        let states = try store.load()
        #expect(states.count == 2)
        #expect(Set(states.map(\.profileID)).count == 2)
        #expect(Set(states.map(\.groupID)).count == 2)
        let first = try #require(states.first { library.group($0.groupID)?.name == "First" })
        let second = try #require(states.first { library.group($0.groupID)?.name == "Second" })
        #expect(model.runningGroups == [first.groupID, second.groupID])
        let retained = try model.connection(for: second.groupID)
        library.replacePersistedSnapshot(.init(groups: library.groups.filter { $0.id != first.groupID }))
        #expect(await settles { probe.erased == [first.profileID] })
        #expect(try store.load().map(\.profileID) == [second.profileID])
        #expect(probe.nodes[second.profileID]?.closed == false)
        #expect(try await retained.hostKeys(stableNodeID: "node").isEmpty)
        #expect(model.runningGroups == [second.groupID])
        await model.shutdown()
    }

    @Test func reloginRejectsRetainedDialersBeforeTheOldNodeHasFinishedClosing() async throws {
        let first = try group("example.ts.net")
        var second = first
        second.id = UUID()
        let library = HostLibraryModel(groups: [first, second])
        let store = InMemoryTailscaleLocalStore()
        let firstProfile = UUID()
        let secondProfile = UUID()
        try store.save(.init(groupID: first.id, profileID: firstProfile))
        try store.save(.init(groupID: second.id, profileID: secondProfile))
        let probe = CleanupProbe(network: try #require(first.tailscale?.network))
        let model = probe.model(library, store: store)
        model.start()
        #expect(await settles { model.runningGroups.count == 2 })
        let retained = try model.connection(for: first.id)
        let independent = try model.connection(for: second.id)
        let old = try #require(probe.nodes[firstProfile])
        old.holdLogout = true
        model.beginLoginAndSave(
            name: first.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil,
            groupID: first.id)
        #expect(await settles { model.loginCompletedGroupID == first.id && old.logoutContinuation != nil })
        #expect(!old.closed)
        await #expect(throws: TailscaleConfigurationError.self) {
            try await retained.open(host: "server", port: 22, timeout: 1)
        }
        await #expect(throws: TailscaleConfigurationError.self) { try await retained.hostKeys(stableNodeID: "node") }
        let replacement = try model.connection(for: first.id)
        #expect(try await replacement.open(host: "server", port: 22, timeout: 1) == 42)
        #expect(try await independent.open(host: "server", port: 22, timeout: 1) == 42)
        old.logoutContinuation?.resume()
        old.logoutContinuation = nil
        #expect(await settles { probe.erased == [firstProfile] })
        #expect(probe.nodes[secondProfile]?.closed == false)

        var changed = try #require(library.group(second.id))
        changed.tailscale = try group("changed.ts.net").tailscale
        library.replacePersistedSnapshot(.init(groups: [try #require(library.group(first.id)), changed]))
        #expect(throws: TailscaleConfigurationError.self) { try model.connection(for: second.id) }
        await #expect(throws: TailscaleConfigurationError.self) { try await independent.hostKeys(stableNodeID: "node") }
        await model.shutdown()
    }

    @Test func rejectedActivationKeepsThePreviousEnrollmentAndErasesTheCandidate() async throws {
        let group = try group("example.ts.net")
        let store = CleanupFailingStore()
        let old = UUID()
        try store.save(.init(groupID: group.id, profileID: old, hostname: "saved"))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(HostLibraryModel(groups: [group]), store: store)
        model.start()
        #expect(await settles { model.runningGroups.contains(group.id) })
        store.failSave = true
        model.beginLoginAndSave(
            name: group.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil,
            groupID: group.id)
        #expect(await settles { probe.created.count == 2 && !probe.erased.isEmpty })
        #expect(try store.load().map(\.profileID) == [old])
        #expect(probe.erased == [probe.created[1]])
        #expect(probe.nodes[old]?.closed == false)
        await model.shutdown()
    }

    @Test func vaultFailureNeverAttemptsToReplaceThePreviousEnrollment() async throws {
        let group = try group("example.ts.net")
        let persistence = CleanupVaultStore(.init(groups: [group]))
        let library = HostLibraryModel(persistence: persistence)
        let store = CleanupFailingStore()
        let old = UUID()
        try store.save(.init(groupID: group.id, profileID: old, hostname: "saved"))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(library, store: store)
        model.start()
        #expect(await settles { model.runningGroups.contains(group.id) })
        let writes = store.saveAttempts
        persistence.failSave = true
        store.failSave = true
        model.beginLoginAndSave(
            name: "renamed", parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil,
            groupID: group.id)
        #expect(await settles { probe.created.count == 2 && !probe.erased.isEmpty })
        #expect(store.saveAttempts == writes)
        #expect(library.group(group.id)?.name == group.name)
        #expect(try store.load().map(\.profileID) == [old])
        #expect(probe.erased == [probe.created[1]])
        #expect(probe.nodes[old]?.closed == false)
        await model.shutdown()
    }

    @Test func newGroupRemainsLoginRequiredWhenLocalActivationFails() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel()
        let store = CleanupFailingStore()
        store.failSave = true
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(library, store: store)
        model.start()
        model.beginLoginAndSave(
            name: group.name, parentID: nil, controlURL: TailscaleNetwork.defaultControlURL, authKey: nil)
        #expect(await settles { !probe.erased.isEmpty })
        #expect(library.groups.first?.tailscale?.network == group.tailscale?.network)
        #expect(model.runningGroups.isEmpty)
        #expect(model.error != nil)
        #expect(try store.load().isEmpty)
        #expect(try store.pendingCleanupProfiles().isEmpty)
        await model.shutdown()
    }

    @Test func failedRetirementPreservesTheEnrollmentUntilItCanBeQueued() async throws {
        let group = try group("example.ts.net")
        let library = HostLibraryModel(groups: [group])
        let store = CleanupFailingStore()
        let profileID = UUID()
        try store.save(.init(groupID: group.id, profileID: profileID))
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        let model = probe.model(library, store: store, access: false)
        model.start()
        store.failRemove = true
        library.replacePersistedSnapshot(.init())
        #expect(model.error != nil)
        #expect(try store.load().map(\.profileID) == [profileID])
        #expect(probe.erased.isEmpty)
        store.failRemove = false
        model.reconcile()
        #expect(await settles { probe.erased == [profileID] })
        #expect(try store.load().isEmpty)
        await model.shutdown()
    }

    @Test func missingCleanupAcknowledgementRetriesAndFailedStateReadsNeverEraseProfiles() async throws {
        let group = try group("example.ts.net")
        let store = CleanupFailingStore()
        let orphan = UUID()
        let probe = CleanupProbe(network: try #require(group.tailscale?.network))
        probe.discovered = [orphan]
        store.failLoad = true
        let unreadable = probe.model(HostLibraryModel(), store: store, access: false)
        unreadable.start()
        #expect(unreadable.error != nil)
        #expect(probe.erased.isEmpty)
        #expect(probe.inventoryReads == 0)
        await unreadable.shutdown()

        store.failLoad = false
        store.failComplete = true
        let model = probe.model(HostLibraryModel(), store: store, access: false)
        model.start()
        #expect(await settles { model.error != nil })
        #expect(probe.erased == [orphan])
        #expect(try store.pendingCleanupProfiles() == [orphan])
        store.failComplete = false
        model.reconcile()
        #expect(await settles { probe.erased.count == 2 })
        #expect(try store.pendingCleanupProfiles().isEmpty)
        await model.shutdown()
    }

    @Test func reopenedStoreNeverErasesAnActiveProfileFromOrphanInventory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Upgrade.store")
        let group = try group("example.ts.net")
        let active = UUID()
        let orphan = UUID()
        try writeStore(url, group: group, profileID: active)
        for _ in 0..<2 {
            let container = try TermindPersistence.makeContainer(url: url)
            let store = SwiftDataTailscaleLocalStore(context: container.mainContext)
            let library = HostLibraryModel(persistence: HostPersistence(context: container.mainContext))
            let probe = CleanupProbe(network: try #require(group.tailscale?.network))
            probe.discovered = [active, orphan]
            let model = probe.model(library, store: store, access: false)
            model.start()
            #expect(await settles { probe.erased == [orphan] })
            #expect(try store.load().map(\.profileID) == [active])
            #expect(library.group(group.id)?.tailscale == group.tailscale)
            #expect(try store.pendingCleanupProfiles().isEmpty)
            await model.shutdown()
        }
    }

    @Test func profileInventoryIncludesOnlyCanonicalUUIDDirectories() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID()
        let directory = root.appendingPathComponent(profile.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("unrelated"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent(UUID().uuidString))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(UUID().uuidString), withDestinationURL: directory)
        #expect(try LibTailscaleNodeSession.storedProfiles(in: root) == [profile])
        #expect(try LibTailscaleNodeSession.storedProfiles(in: root.appendingPathComponent("missing")).isEmpty)
    }

    private func writeStore(_ url: URL, group: HostGroup, profileID: UUID) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        _ = try HostPersistence(context: container.mainContext).save(.init(groups: [group]))
        try SwiftDataTailscaleLocalStore(context: container.mainContext).save(
            TailscaleLocalState(groupID: group.id, profileID: profileID, hostname: "saved"))
    }

    private func group(_ suffix: String) throws -> HostGroup {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: suffix)
        var group = HostGroup(name: suffix)
        group.tailscale = TailscaleGroupConfiguration(network: network)
        return group
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func settles(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

@MainActor private final class CleanupProbe {
    let network: TailscaleNetwork
    var created: [UUID] = []
    var erased: [UUID] = []
    var events: [String] = []
    var nodes: [UUID: CleanupNode] = [:]
    var discovered: Set<UUID> = []
    var inventoryReads = 0
    var failErase = false
    var holdFactory = false
    var failFactory = false
    var factoryContinuation: CheckedContinuation<Void, Never>?

    init(network: TailscaleNetwork) { self.network = network }

    func model(_ library: HostLibraryModel, store: any TailscaleLocalStoring, access: Bool = true) -> TailscaleModel {
        TailscaleModel(
            library: library, store: store, factory: { id, _, _, _ in try await self.make(id) },
            profileStorage: .init(profiles: { await self.inventory() }, erase: { try await self.erase($0) }),
            hostname: { "test" }, hasAccess: { access })
    }

    func make(_ id: UUID) async throws -> any TailscaleNodeSession {
        created.append(id)
        if holdFactory { await withCheckedContinuation { factoryContinuation = $0 } }
        if failFactory { throw CocoaError(.fileReadUnknown) }
        let node = CleanupNode(network: network) { self.events.append("close:\(id)") }
        nodes[id] = node
        return node
    }
    func releaseFactory() {
        factoryContinuation?.resume()
        factoryContinuation = nil
        holdFactory = false
    }
    func inventory() -> Set<UUID> {
        inventoryReads += 1
        return discovered
    }
    func erase(_ id: UUID) throws {
        #expect(nodes[id]?.closed != false)
        if failErase { throw CocoaError(.fileWriteNoPermission) }
        events.append("erase:\(id)")
        erased.append(id)
    }
}

@MainActor private final class CleanupNode: TailscaleNodeSession {
    let network: TailscaleNetwork
    let onClose: () -> Void
    var closed = false
    var holdLogout = false
    var logoutContinuation: CheckedContinuation<Void, Never>?
    init(network: TailscaleNetwork, onClose: @escaping () -> Void) {
        self.network = network
        self.onClose = onClose
    }
    func status() async throws -> TailscaleNodeStatus {
        .init(running: true, network: network, authURL: nil, peers: [])
    }
    func login() async throws {}
    func setHostname(_ hostname: String) async throws {}
    @MainActor func logout() async throws {
        if holdLogout { await withCheckedContinuation { logoutContinuation = $0 } }
    }
    func close() async {
        await MainActor.run {
            if !closed {
                closed = true
                onClose()
            }
        }
    }
    func dial(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { 42 }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}

@MainActor private final class CleanupFailingStore: TailscaleLocalStoring {
    let base = InMemoryTailscaleLocalStore()
    var failSave = false
    var failLoad = false
    var failComplete = false
    var failRemove = false
    var saveAttempts = 0
    func load() throws -> [TailscaleLocalState] {
        if failLoad { throw CocoaError(.fileReadUnknown) }
        return try base.load()
    }
    func save(_ state: TailscaleLocalState) throws {
        saveAttempts += 1
        if failSave { throw CocoaError(.fileWriteUnknown) }
        try base.save(state)
    }
    func remove(groupID: UUID) throws {
        if failRemove { throw CocoaError(.fileWriteUnknown) }
        try base.remove(groupID: groupID)
    }
    func scheduleCleanup(profileID: UUID) throws { try base.scheduleCleanup(profileID: profileID) }
    func pendingCleanupProfiles() throws -> Set<UUID> { try base.pendingCleanupProfiles() }
    func completeCleanup(profileID: UUID) throws {
        if failComplete { throw CocoaError(.fileWriteUnknown) }
        try base.completeCleanup(profileID: profileID)
    }
}

@MainActor private final class CleanupVaultStore: VaultPersisting {
    var snapshot: VaultSnapshot
    var failSave = false
    init(_ snapshot: VaultSnapshot) { self.snapshot = snapshot }
    func load() throws -> VaultSnapshot { snapshot }
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        self.snapshot = snapshot
        return .empty
    }
}

import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileTerminalRestorationTests {
    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func remoteEndClosesWorkspaceOnceButRecoveryAndFailureDoNot(_ transport: HostTerminalProtocol) {
        let host = Host(name: "Server", host: "example.invalid")
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .terminal(transport)),
            hosts: HostLibraryModel(hosts: [host]))
        defer { workspace.disconnect() }
        var closed: [UUID] = []
        workspace.didRequestClose = { closed.append($0) }

        workspace.receiveTransportState(.recovering)
        workspace.receiveTransportState(.failed)
        #expect(closed.isEmpty)
        workspace.receiveTransportState(.ended)
        #expect(closed == [workspace.id])
        workspace.receiveTransportState(.connected)
        workspace.receiveTransportState(.ended)
        #expect(closed == [workspace.id])
        #expect(!workspace.connected)
        #expect(!workspace.busy)
    }

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func savedTmuxReferenceSurvivesTransportRecoveryAndMissingCheckpoint(_ transport: HostTerminalProtocol) async throws
    {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try MobileAppModel(inMemory: true)
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.sessionPersistence.enabled = true
        seed.library.upsert(host)
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "$4", name: "build", identity: Data("identity".utf8)),
            hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: nil)
        let descriptor = MobileWorkspaceDescriptor(
            hostID: host.id, title: "tmux", kind: .terminal(transport), remoteSession: reference)
        try MobileWorkspaceStore(defaults: fixture.defaults).save(.init(sessions: ["scene": [descriptor]]))
        var dependencies = MobileAppDependencies.testing(defaults: fixture.defaults)
        dependencies.container = seed.container
        dependencies.terminalRecoveryStore = fixture.recovery
        let app = try MobileAppModel(dependencies: dependencies)
        let workspace = try #require(app.workspaceSession(for: "scene").openWorkspace(descriptor.id))
        defer { workspace.disconnect() }
        #expect(workspace.sessionPersistence.attachment == reference)
        #expect(workspace.requiresTransportRecovery)

        workspace.connect()

        #expect(await eventually { workspace.journey.phase == .waiting })
        #expect(!workspace.requiresTransportRecovery)
        #expect(workspace.sessionPersistence.attachment == reference)
        #expect(workspace.sessionPersistence.requiresSelection)
        #expect(workspace.pendingInitialCommand == nil)
        #expect(workspace.journey.purpose == .terminal(transport))
    }

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func connectionJourneyUsesTheSelectedTransportInsteadOfSSH(_ transport: HostTerminalProtocol) async {
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        let store = HostLibraryModel(hosts: [host])
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .terminal(transport)), hosts: store)
        defer { workspace.disconnect() }

        workspace.connect()

        #expect(workspace.journey.purpose == .terminal(transport))
        #expect(workspace.journey.plainTextLog.contains("Starting \(transport.displayName) session"))
        #expect(await eventually { workspace.journey.phase == .waiting })
    }

    @Test func coldLaunchKeepsResumableAndTmuxWorkspacesInTheirOriginalListsWithoutConnecting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try MobileAppModel(inMemory: true)
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.sessionPersistence.enabled = true
        seed.library.upsert(host)
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "$4", name: "build", identity: Data("identity".utf8)),
            hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: nil)
        let mosh = MobileWorkspaceDescriptor(hostID: host.id, title: "Mosh", kind: .mosh)
        let et = MobileWorkspaceDescriptor(hostID: host.id, title: "ET", kind: .eternalTerminal)
        let tmux = MobileWorkspaceDescriptor(
            hostID: host.id, title: "tmux", kind: .ssh, remoteSession: reference)
        try MobileWorkspaceStore(defaults: fixture.defaults).save(.init(sessions: ["one": [mosh, tmux], "two": [et]]))
        var connections = 0
        var dependencies = MobileAppDependencies.testing(defaults: fixture.defaults)
        dependencies.container = seed.container
        dependencies.terminalRecoveryStore = fixture.recovery
        dependencies.workspaceConnections.connectSSH = { _, _, _, _, _, _ in connections += 1 }
        let app = try MobileAppModel(dependencies: dependencies)
        #expect(app.workspaceSession(for: "one").savedWorkspaceDescriptors == [mosh, tmux])
        #expect(app.workspaceSession(for: "two").savedWorkspaceDescriptors == [et])
        #expect(app.workspaces.isEmpty)
        #expect(connections == 0)
        app.workspaceSession(for: "one").close(mosh.id, rememberForReopen: false)
        let saved = try MobileWorkspaceStore(defaults: fixture.defaults).load()
        #expect(saved.sessions["one"] == [tmux])
        #expect(saved.sessions["two"] == [et])
        let workspace = try #require(app.workspaceSession(for: "one").openWorkspace(tmux.id))
        #expect(workspace.sessionPersistence.attachment == reference)
        #expect(workspace.sessionPersistence.requiresSelection)
        workspace.disconnect()
    }

    @Test func missingCheckpointNeverBootstrapsANewShellEvenAfterRepeatedSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try MobileAppModel(inMemory: true)
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        seed.library.upsert(host)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Old shell", kind: .mosh)
        try MobileWorkspaceStore(defaults: fixture.defaults).save(.init(sessions: ["scene": [descriptor]]))
        var connections = 0
        var dependencies = MobileAppDependencies.testing(defaults: fixture.defaults)
        dependencies.container = seed.container
        dependencies.terminalRecoveryStore = fixture.recovery
        dependencies.workspaceConnections.connectSSH = { _, _, _, _, _, _ in connections += 1 }
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app, sessionID: "scene")
        scene.selectedDestination = .workspaces
        scene.open(descriptor.destinationURL)
        let workspace = try #require(scene.activeWorkspace)
        #expect(await eventually { workspace.transportState == .failed })
        scene.open(descriptor.destinationURL)
        workspace.connect()
        #expect(await eventually { workspace.transportState == .failed })
        #expect(app.workspaces.count == 1)
        #expect(workspace.requiresTransportRecovery)
        #expect(connections == 0)
        scene.workspaceSession.closeAll()
        scene.open(descriptor.destinationURL)
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
    }

    @Test func activityRestoresTheSavedMoshOnceWithoutTargetSSHCredentialsOrStartupReplay() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try MobileAppModel(inMemory: true)
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        seed.library.upsert(host)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Old shell", kind: .mosh)
        try MobileWorkspaceStore(defaults: fixture.defaults).save(.init(sessions: ["scene": [descriptor]]))
        let record = TerminalRecoveryRecord(
            id: descriptor.id, host: host, username: "original-user", transport: .mosh)
        let lease = await fixture.recovery.register(record.id)
        try await fixture.recovery.save(
            record, checkpoint: .init(transport: .mosh, payload: Data("opaque".utf8)), lease: lease)
        var connections = 0
        var writes: [Data] = []
        var dependencies = MobileAppDependencies.testing(defaults: fixture.defaults)
        dependencies.container = seed.container
        dependencies.terminalRecoveryStore = fixture.recovery
        dependencies.workspaceConnections.connectSSH = { _, request, _, _, _, _ in
            connections += 1
            #expect(request.configuration.username == "original-user")
            #expect(request.configuration.credentials.isEmpty)
            #expect(request.configuration.jumps.isEmpty)
        }
        dependencies.workspaceConnections.writeSSH = { _, data in writes.append(data) }
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app, sessionID: "scene")
        scene.selectedDestination = .workspaces
        let card = WorkspaceActivityAttributes.Session(
            id: descriptor.id, title: descriptor.title, kind: "mosh", connected: false,
            recovery: .init(sourceWorkspaceID: descriptor.id, hostID: host.id, kind: "mosh"))
        scene.open(card.destinationURL)
        scene.open(card.destinationURL)
        #expect(await eventually { scene.activeWorkspace?.connected == true })
        #expect(app.workspaces.count == 1)
        #expect(scene.activeWorkspace?.id == descriptor.id)
        #expect(connections == 1)
        #expect(writes.isEmpty)
        #expect(try await fixture.recovery.records().isEmpty)
        scene.workspaceSession.closeAll()
        scene.open(card.destinationURL)
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
    }

    @Test func unknownSnapshotVersionIsNotOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let data = Data("{\"version\":99,\"sessions\":{}}".utf8)
        fixture.defaults.set(data, forKey: MobileWorkspaceStore.restorationKey)
        let store = MobileWorkspaceStore(defaults: fixture.defaults)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(throws: (any Error).self) { try store.save(.init()) }
        #expect(fixture.defaults.data(forKey: MobileWorkspaceStore.restorationKey) == data)
    }

    @Test func restorationWaitsForHostDiscoveryWithoutDeletingItsDescriptor() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "Tailnet", kind: .eternalTerminal)
        try MobileWorkspaceStore(defaults: fixture.defaults).save(.init(sessions: ["scene": [descriptor]]))
        let app = try MobileAppModel(dependencies: .testing(defaults: fixture.defaults))
        let session = app.workspaceSession(for: "scene")
        #expect(session.openWorkspace(descriptor.id) == nil)
        app.persistWorkspaceDescriptors()
        #expect(try MobileWorkspaceStore(defaults: fixture.defaults).load().sessions["scene"] == [descriptor])
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private struct Fixture {
        let name = "TerminalRestoration.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let recovery: TerminalRecoveryStore
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            recovery = TerminalRecoveryStore(directory: directory, testingKey: Data(repeating: 9, count: 32))
        }
        func cleanUp() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

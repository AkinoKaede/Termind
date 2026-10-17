import Foundation
import GhosttyTerminal
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileAppTests {
    private final class MetricsPreferences: MetricsConfigurationStoring {
        var values: [MetricsSelection] = []
        func load() -> [MetricsSelection] { values }
        func save(_ selections: [MetricsSelection]) { values = selections }
    }

    @Test func startupUsesTheSharedSchemaAndEmptyRepository() throws {
        let app = try MobileAppModel(inMemory: true)
        #expect(try app.hosts.snapshot().value == .empty)
        #expect(Set(app.container.schema.entities.map(\.name)) == Set(TermindPersistence.schema.entities.map(\.name)))
        let features = MobileFeatureRegistry.standard()
        #expect(features.registrations.map(\.id) == [.vault, .metrics, .workspaces, .assistant, .settings])
    }

    @Test func memoryCompositionCannotStartOrEraseLiveTailscaleProfiles() async throws {
        var dependencies = MobileAppDependencies.testing()
        let container = try TermindPersistence.makeContainer(inMemory: true)
        dependencies.container = container
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        _ = try HostPersistence(context: container.mainContext).save(.init(groups: [group]))
        let store = SwiftDataTailscaleLocalStore(context: container.mainContext)
        let profileID = UUID()
        try store.save(.init(groupID: group.id, profileID: profileID))
        let app = try MobileAppModel(dependencies: dependencies)
        defer { app.outbox.stop() }
        for _ in 0..<200 where app.tailscale.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(app.tailscale.error != nil)
        #expect(app.tailscale.runningGroups.isEmpty)
        await app.tailscale.logout(groupID: group.id)
        #expect(try store.pendingCleanupProfiles() == [profileID])
        await app.tailscale.shutdown()
    }

    @Test func scenesCanUseTheSameAppRepository() throws {
        let repository = InMemoryHostRepository()
        let app = try MobileAppModel(hosts: repository)
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        try repository.upsertHost(host)
        #expect(try app.hosts.snapshot().value.hosts == [host])
    }

    @Test func assistantNavigationAndDraftsAreSceneLocalWhileConversationsAreShared() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = MobileSceneModel(app: app, sessionID: "test")
        let second = MobileSceneModel(app: app, sessionID: "other")
        first.assistant.conversation.composer.draft = "first draft"
        second.assistant.conversation.composer.draft = "second draft"

        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Shared")])
        first.assistant.library.insertAndSelect(conversation)

        #expect(second.assistant.library.conversation(id: conversation.id) === conversation)
        #expect(second.assistant.library.selectedConversation == nil)
        #expect(second.assistant.conversation.composer.draft == "second draft")

        second.assistant.select(conversation)
        first.assistant.newConversation()

        #expect(second.assistant.conversation === conversation)
        #expect(first.assistant.conversation !== conversation)
        #expect(first.assistant.conversation.composer.draft.isEmpty)
    }

    @Test func historyBelongsToWorkspaceAndIsReleasedOnClose() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Host", host: "example.invalid")
        let first = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        let second = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        first.commandHistory.record("pwd")
        first.sftpHistory.record(kind: .directory, path: "/srv")
        #expect(second.commandHistory.entries().isEmpty)
        #expect(second.sftpHistory.entries().isEmpty)
        first.close()
        #expect(first.commandHistory.entries().isEmpty)
        #expect(first.sftpHistory.entries().isEmpty)
    }

    @Test func clearingRecentsPreservesCommandAndFileHistory() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let host = TermindDomain.Host(name: "Recent", host: "recent.example.invalid")
        app.library.upsert(host)
        _ = app.connectionHistory.record(kind: .ssh, for: host.id)
        let workspace = MobileWorkspace(
            descriptor: .init(hostID: host.id, title: host.name, kind: .ssh), hosts: app.library)
        workspace.commandHistory.record("pwd")
        workspace.sftpHistory.record(kind: .directory, path: "/srv")

        app.connectionHistory.clear(for: host.id)

        #expect(app.connectionHistory.entries(for: host.id).isEmpty)
        #expect(workspace.commandHistory.entries().map(\.command) == ["pwd"])
        #expect(workspace.sftpHistory.entries().map(\.path) == ["/srv"])
    }
}

@Suite @MainActor
struct MobileWorkspaceTests {
    @Test func externalConnectionWorkspaceIsEphemeralAndDoesNotTouchVault() throws {
        let app = try MobileAppModel(inMemory: true)
        let request = try RemoteConnectionURLParser.parse(
            #require(URL(string: "ssh://deploy@example.invalid:2222")))
        let id = try #require(app.testWorkspaceSession.openExternalConnection(request))
        let workspace = try #require(app.workspaces.first { $0.id == id })

        #expect(workspace.isExternalTemporaryConnection)
        #expect(workspace.descriptor.title == "example.invalid")
        #expect(app.testWorkspaceSession.savedWorkspaceDescriptors.isEmpty)
        #expect(app.library.hosts.isEmpty)
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.map(\.id) == [id])
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.first?.loginAddress == "deploy@example.invalid:2222")

        let savedHost = TermindDomain.Host(name: "Saved", host: "saved.example.invalid")
        app.library.upsert(savedHost)
        let savedID = try #require(app.testWorkspaceSession.open(hostID: savedHost.id, kind: .ssh))
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.map(\.id) == [id, savedID])

        app.testWorkspaceSession.close(id)
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.map(\.id) == [savedID])
        app.testWorkspaceSession.close(savedID)
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.isEmpty)
    }

    @Test func liveActivitiesUseStableDistinctWorkspaceDestinations() {
        let first = MobileWorkspaceDescriptor(hostID: UUID(), title: "Server", kind: .ssh)
        var renamed = first
        renamed.title = "Renamed"
        let second = MobileWorkspaceDescriptor(hostID: first.hostID, title: "Server", kind: .sftp)
        #expect(first.destinationURL == renamed.destinationURL)
        #expect(first.destinationURL != second.destinationURL)
    }

    @Test func renamingUpdatesActivityStateWithoutChangingIdentity() throws {
        let descriptor = MobileWorkspaceDescriptor(hostID: UUID(), title: "Production", kind: .ssh)
        let workspace = MobileWorkspace(descriptor: descriptor, hosts: HostLibraryModel())
        var activityTitle: String?
        workspace.didChangeState = { activityTitle = $0.title }

        #expect(!workspace.rename(to: "   "))
        #expect(workspace.rename(to: "  Release Shell  "))
        #expect(workspace.id == descriptor.id)
        #expect(workspace.descriptor.title == "Release Shell")
        #expect(workspace.activitySession.title == "Release Shell")
        #expect(activityTitle == "Release Shell")
        #expect(!workspace.rename(to: "Release Shell"))
    }

    @Test func automaticTitlesUseVisibleNamesAcrossProtocolsAndAppendAfterTheMaximum() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Server", host: "example.invalid")
        app.library.upsert(host)
        defer { app.testWorkspaceSession.closeAll() }

        let firstID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let secondID = try #require(
            app.testWorkspaceSession.open(hostID: host.id, kind: .ssh, initialPath: "/srv/releases"))
        let thirdID = try #require(
            app.testWorkspaceSession.execute(Snippet(title: "Status", body: "uptime"), on: [host.id]).first)
        let sftpID = try #require(
            app.testWorkspaceSession.open(hostID: host.id, kind: .sftp, initialPath: "/srv/releases"))

        let first = try #require(app.workspaces.first { $0.id == firstID })
        let second = try #require(app.workspaces.first { $0.id == secondID })
        let third = try #require(app.workspaces.first { $0.id == thirdID })
        let sftp = try #require(app.workspaces.first { $0.id == sftpID })
        #expect(
            [first, second, third, sftp].map(\.descriptor.title)
                == ["Server", "Server (1)", "Server (2)", "Server (3)"])
        #expect(third.activitySession.title == "Server (2)")

        #expect(app.testWorkspaceSession.renameWorkspace(secondID, to: "Logs"))
        let fourthID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let fourth = try #require(app.workspaces.first { $0.id == fourthID })
        #expect(fourth.descriptor.title == "Server (4)")

        app.testWorkspaceSession.close(firstID)
        let recycledBaseID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let recycledBase = try #require(app.workspaces.first { $0.id == recycledBaseID })
        #expect(recycledBase.descriptor.title == "Server")
        #expect(second.descriptor.title == "Logs")
        #expect(third.descriptor.title == "Server (2)")
        #expect(fourth.descriptor.title == "Server (4)")

        app.testWorkspaceSession.close(secondID)
        let recycledOneID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let recycledOne = try #require(app.workspaces.first { $0.id == recycledOneID })
        #expect(recycledOne.descriptor.title == "Server (5)")

        #expect(app.workspaceSettings.setAutomaticRenaming(false))
        let unnumberedID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        #expect(app.workspaces.first { $0.id == unnumberedID }?.descriptor.title == "Server")
    }

    @Test func hostNamesThatEndInNumbersDoNotConflictWithParenthesizedSuffixes() throws {
        let app = try MobileAppModel(inMemory: true)
        let server = TermindDomain.Host(name: "Server", host: "server.example")
        let serverOne = TermindDomain.Host(name: "Server 1", host: "server-one.example")
        app.library.upsert(server)
        app.library.upsert(serverOne)
        defer { app.testWorkspaceSession.closeAll() }

        let ids = [
            try #require(app.testWorkspaceSession.open(hostID: server.id, kind: .ssh)),
            try #require(app.testWorkspaceSession.open(hostID: serverOne.id, kind: .sftp)),
            try #require(app.testWorkspaceSession.open(hostID: server.id, kind: .sftp)),
            try #require(app.testWorkspaceSession.open(hostID: serverOne.id, kind: .ssh)),
        ]
        #expect(
            ids.compactMap { id in app.workspaces.first { $0.id == id }?.descriptor.title }
                == ["Server", "Server 1", "Server (1)", "Server 1 (1)"])
    }

    @Test func closeAllDisconnectsAndRemovesEveryWorkspaceAndIsRepeatable() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        let opened = app.workspaces

        app.testWorkspaceSession.closeAll()

        #expect(app.workspaces.isEmpty)
        #expect(opened.allSatisfy { !$0.connected && $0.status == String(localized: "Disconnected") })

        app.testWorkspaceSession.closeAll()
        #expect(app.workspaces.isEmpty)
    }

    @Test func closeOtherWorkspacesKeepsTheTargetAndRemovesOpenedAndRecentWorkspaces() throws {
        let suite = "termind.close-other-workspaces.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let seed = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        seed.library.upsert(host)
        let descriptors = [
            MobileWorkspaceDescriptor(hostID: host.id, title: "Keep", kind: .ssh),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Opened", kind: .sftp),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Recent", kind: .ssh),
        ]
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = seed.container
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        app.testWorkspaceSession.restoreClosedStates(descriptors.map { .init(descriptor: $0) })
        let kept = try #require(app.testWorkspaceSession.openWorkspace(descriptors[0].id))
        let opened = try #require(app.testWorkspaceSession.openWorkspace(descriptors[1].id))
        #expect(app.testWorkspaceSession.closableWorkspaceCount == 3)
        #expect(scene.canCloseMultipleWorkspaces)

        scene.closeOtherWorkspaces(than: kept.id)

        #expect(app.workspaces.map(\.id) == [kept.id])
        #expect(app.testWorkspaceSession.savedWorkspaceDescriptors == [kept.descriptor])
        #expect(app.testWorkspaceSession.recentWorkspaces.isEmpty)
        #expect(!opened.connected)
        #expect(opened.status == String(localized: "Disconnected"))
        #expect(defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(!scene.canCloseMultipleWorkspaces)
        app.testWorkspaceSession.closeAll()
    }

    @Test func hostEditsPersistThroughTheSharedVaultStore() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        #expect(app.library.storageError == nil)
        let store = HostPersistence(context: ModelContext(app.container))
        #expect(try store.load().hosts == app.library.hosts)
        #expect(try store.load().hosts.first?.id == host.id)
    }

    @Test func metricsHasNoIndependentSelectionLimitAndDeduplicates() {
        let library = HostLibraryModel()
        let hosts = (0..<5).map { TermindDomain.Host(name: "Host \($0)", host: "example.invalid") }
        for host in hosts { library.upsert(host) }
        let metrics = MobileMetricsModel(
            preferences: MetricsPreferences(), hosts: library, services: .testing)
        metrics.pause()
        defer { metrics.core.shutdown() }
        for host in hosts {
            let added = metrics.add(host.id)
            #expect(added)
        }
        let repeated = metrics.add(hosts[0].id)
        #expect(repeated)
        #expect(metrics.selections.map(\.id) == hosts.map(\.id))
    }
}

@Suite @MainActor
struct MobileWorkspaceConnectionRecoveryTests {
    @Test(arguments: [HostTerminalProtocol.ssh, .mosh, .eternalTerminal])
    func sameDirectorySFTPUsesTheDefaultTransportOnlyWhileConnected(_ transport: HostTerminalProtocol) async throws {
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        var host = try configureConnectionFixture(in: app)
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        host.terminalTransports.defaultTransport = transport
        app.library.upsert(host)
        let id = try #require(
            app.testWorkspaceSession.open(hostID: host.id, kind: .sftp, initialPath: "/srv/releases/"))
        let workspace = try #require(app.workspaces.first(where: { $0.id == id }))
        defer { app.testWorkspaceSession.close(id) }

        #expect(workspace.sameDirectoryLaunch == nil)
        #expect(await eventually { workspace.connected })
        #expect(workspace.sftpChannel.path == "/srv/releases")
        #expect(
            workspace.sameDirectoryLaunch
                == MobileWorkspaceDirectoryLaunch(
                    hostID: host.id, kind: .terminal(transport), path: "/srv/releases")
        )
        #expect(app.testWorkspaceSession.renameWorkspace(id, to: "  Release Files  "))
        #expect(workspace.descriptor.title == "Release Files")

        workspace.disconnect()
        #expect(workspace.sameDirectoryLaunch == nil)
    }

    @Test func backgroundExpirationResumesEveryAffectedWorkspaceOnForeground() async throws {
        let background = MobileTestBackgroundTaskManager()
        let connections = MobileSFTPConnectionBox(
            clients: [
                MobileTestSFTPClient(), MobileTestSFTPClient(),
                MobileTestSFTPClient(), MobileTestSFTPClient(),
            ])
        let app = try MobileAppModel(
            inMemory: true, background: background, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        let sceneID = UUID()
        app.sceneChanged(sceneID, phase: .active)
        app.sceneChanged(sceneID, phase: .background)

        background.expire()

        #expect(app.workspaces.allSatisfy { !$0.connected && $0.journey.isPresented })
        #expect(app.workspaces.allSatisfy { $0.journey.mode == .reconnection })
        #expect(connections.connectCount == 2)

        app.sceneChanged(sceneID, phase: .active)

        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        #expect(connections.connectCount == 4)
    }

    @Test func returningBeforeBackgroundExpirationKeepsHealthyConnection() async throws {
        let background = MobileTestBackgroundTaskManager()
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(
            inMemory: true, background: background, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(await eventually { app.workspaces.first?.connected == true })
        let sceneID = UUID()
        app.sceneChanged(sceneID, phase: .active)
        app.sceneChanged(sceneID, phase: .background)

        app.sceneChanged(sceneID, phase: .active)
        background.expire()

        #expect(app.workspaces.first?.connected == true)
        #expect(connections.connectCount == 1)
    }

    @Test func removingTheLastActiveSceneStartsOneBackgroundLeaseForRemainingScenes() async throws {
        let background = MobileTestBackgroundTaskManager()
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(
            inMemory: true, background: background, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        _ = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(await eventually { app.workspaces.first?.connected == true })
        let backgroundScene = UUID()
        let activeScene = UUID()
        app.sceneChanged(backgroundScene, phase: .active)
        app.sceneChanged(activeScene, phase: .active)
        app.sceneChanged(backgroundScene, phase: .background)

        app.removeScene(activeScene)

        #expect(background.beginCount == 1)
        #expect(app.workspaces.first?.connected == true)
        app.removeScene(activeScene)
        #expect(background.beginCount == 1)
        background.expire()
        #expect(app.workspaces.first?.connected == false)

        app.removeScene(backgroundScene)
        #expect(background.beginCount == 1)
    }

    @Test func removingABackgroundSceneWhileAnotherSceneIsVisibleDoesNotStartALease() throws {
        let background = MobileTestBackgroundTaskManager()
        let app = try MobileAppModel(inMemory: true, background: background)
        let backgroundScene = UUID()
        let activeScene = UUID()
        app.sceneChanged(backgroundScene, phase: .active)
        app.sceneChanged(activeScene, phase: .active)
        app.sceneChanged(backgroundScene, phase: .background)

        app.removeScene(backgroundScene)

        #expect(background.beginCount == 0)
        app.removeScene(activeScene)
        #expect(background.beginCount == 0)
    }

    @Test func failedForegroundResumeKeepsReconnectionJourneyVisible() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let reconnectController = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library, connectionServices: connections.services,
            reconnectController: reconnectController)
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })

        workspace.suspendForBackgroundExpiration()
        workspace.resumeAfterBackground()

        #expect(await eventually { workspace.reconnectState?.attempt == 1 })
        #expect(workspace.journey.isPresented)
        #expect(workspace.journey.mode == .reconnection)
        #expect(workspace.operationError == nil)
    }

    @Test func explicitDisconnectDoesNotCreateAResumeIntent() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient(), MobileTestSFTPClient()])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library, connectionServices: connections.services)
        workspace.connect()
        #expect(await eventually { workspace.connected })

        workspace.disconnect()
        workspace.resumeAfterBackground()

        #expect(!workspace.connected)
        #expect(!workspace.journey.isPresented)
        #expect(connections.connectCount == 1)
    }

    @Test func backgroundExpirationClearsPendingAuthenticationBeforeResume() async throws {
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        let library = HostLibraryModel(
            hosts: [host],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        let connections = MobileSFTPConnectionBox(clients: [])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library, connectionServices: connections.services)
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.authenticationPrompt != nil })

        workspace.suspendForBackgroundExpiration()

        #expect(workspace.authenticationPrompt == nil)
        #expect(!workspace.authenticationRequired)
        #expect(workspace.journey.isPresented)
        #expect(workspace.journey.mode == .connection)

        workspace.resumeAfterBackground()
        #expect(await eventually { workspace.authenticationPrompt != nil })
    }

    @Test func initialConnectionFailureStaysInJourney() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            connectionServices: connections.services)
        defer { workspace.disconnect() }

        workspace.connect()

        #expect(
            await eventually {
                if case .failed = workspace.journey.phase { return true }
                return false
            })
        #expect(workspace.operationError == nil)
    }

    @Test func authenticationPersistenceFailureRemainsInJourneyForm() async throws {
        let message = "Keychain unavailable"
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        let library = HostLibraryModel(
            hosts: [host],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ],
            secrets: MobileFailingSecretStore(message: message))
        let connections = MobileSFTPConnectionBox(clients: [])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            connectionServices: connections.services)
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.authenticationPrompt != nil })
        workspace.submitAuthentication(
            identityID: nil, username: "deploy", password: "test-only", passphrase: nil, keyID: nil, save: true)

        #expect(workspace.authenticationPrompt?.failureMessage == message)
        #expect(workspace.journey.phase == .waiting)
        #expect(workspace.operationError == nil)
    }

    @Test func sftpOperationFailureUsesOperationErrorWithoutFailingJourney() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [MobileOperationFailingSFTPClient()])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            connectionServices: connections.services)
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.connected })
        await workspace.sftpChannel.openDirectory("/restricted")

        #expect(workspace.sftpChannel.operationError == "Permission denied")
        if case .failed = workspace.journey.phase {
            Issue.record("An ordinary SFTP operation error must not fail the connection Journey")
        }
    }

    @Test func disconnectClearsJourneyAndOperationErrors() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            connectionServices: connections.services)
        workspace.operationError = "Permission denied"
        workspace.connect()
        #expect(await eventually { workspace.journey.isPresented })

        workspace.disconnect()

        #expect(!workspace.journey.isPresented)
        #expect(workspace.operationError == nil)
    }

    @Test func sftpUnexpectedLossReconnectsWithoutResettingTheCurrentPath() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519, fingerprint: "SHA256:test")
            ])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient(), MobileTestSFTPClient()])
        let reconnectController = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            connectionServices: connections.services,
            reconnectController: reconnectController)
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.connected })
        await workspace.sftpChannel.openDirectory("/srv/project")
        #expect(workspace.sftpChannel.path == "/srv/project")

        let retiredConnectionFailure = connections.connectionFailure
        retiredConnectionFailure?("offline")
        retiredConnectionFailure?("duplicate offline callback")
        #expect(await eventually { workspace.reconnectState?.attempt == 1 })
        #expect(workspace.journey.mode == .reconnection)
        #expect(workspace.operationError == nil)
        workspace.retryReconnectNow()

        #expect(await eventually { workspace.connected })
        #expect(workspace.sftpChannel.path == "/srv/project")
        #expect(connections.connectCount == 2)

        retiredConnectionFailure?("stale callback")
        try await Task.sleep(for: .milliseconds(20))
        #expect(workspace.connected)
        #expect(workspace.reconnectState == nil)
    }

    @Test func sftpConnectionPublishesRouteProgressToJourney() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(
            clients: [MobileTestSFTPClient()],
            progressEvents: [
                .connecting(host.id), .authenticating(host.id), .authenticated(host.id),
            ])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library, connectionServices: connections.services)
        defer { workspace.disconnect() }

        workspace.connect()

        #expect(await eventually { workspace.connected })
        #expect(await eventually { workspace.journey.logs.count >= 6 })
        #expect(connections.didReceiveProgressHandler)
        #expect(workspace.journey.purpose == .sftpChannel)
    }

    @Test func sshUnexpectedExitReconnectsOnceAndRejectsRetiredCallbacks() async throws {
        let (host, library) = try connectionFixture()
        let connections = MobileSFTPConnectionBox(clients: [])
        let reconnectController = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library, connectionServices: connections.services,
            reconnectController: reconnectController)
        var closeRequest: MobileWorkspace.ID?
        workspace.didRequestClose = { closeRequest = $0 }
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.connected })
        let retiredExit = try #require(connections.sshExitHandlers.first)

        retiredExit(.failure(.socket("offline")))
        #expect(await eventually { workspace.reconnectState?.attempt == 1 })
        #expect(closeRequest == nil)
        workspace.retryReconnectNow()

        #expect(await eventually { workspace.connected })
        #expect(connections.sshConnectCount == 2)
        retiredExit(.success(0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(workspace.connected)
        #expect(workspace.reconnectState == nil)
        #expect(closeRequest == nil)
    }

    @Test func successfulSSHExitClosesOnlyItsWorkspaceAndAcceptsAnyExitStatus() async throws {
        let connections = MobileSFTPConnectionBox(clients: [])
        let app = try MobileAppModel(
            inMemory: true, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        let firstID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        #expect(
            await eventually {
                app.workspaces.first(where: { $0.id == firstID })?.connected == true
                    && connections.sshExitHandlers.count == 1
            })

        let secondID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(
            await eventually {
                app.workspaces.first(where: { $0.id == secondID })?.connected == true
                    && connections.sshExitHandlers.count == 2
            })

        connections.sshExitHandlers[0](.success(0))
        #expect(
            await eventually {
                !app.workspaces.contains(where: { $0.id == firstID })
                    && app.workspaces.contains(where: { $0.id == secondID })
            })

        connections.sshExitHandlers[0](.success(0))
        try await Task.sleep(for: .milliseconds(20))
        #expect(app.workspaces.map(\.id) == [secondID])

        connections.sshExitHandlers[1](.success(23))
        #expect(await eventually { app.workspaces.isEmpty })
    }

    @Test func onlySuccessfulSessionsEnterAutomaticRecovery() {
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let state = RemoteSessionConnectionController(reconnect: controller)
        defer { state.resetRecovery() }

        #expect(!state.scheduleRecovery(after: "initial failure") {})
        #expect(state.reconnectState == nil)
        #expect(!state.markConnected())
        #expect(state.scheduleRecovery(after: "connection lost") {})
        #expect(state.isRecovering)
        #expect(state.reconnectState?.attempt == 1)
        #expect(!state.scheduleRecovery(after: "still offline") {})
        #expect(state.reconnectState?.attempt == 2)
    }

    @Test func stoppingRecoveryKeepsManualReconnectAvailableAndResetClearsHistory() {
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let state = RemoteSessionConnectionController(reconnect: controller)
        _ = state.markConnected()
        _ = state.scheduleRecovery(after: "offline") {}

        #expect(state.stopRecovery()?.lastError == "offline")
        #expect(state.reconnectState == nil)
        #expect(state.hasConnectedOnce)
        #expect(!state.isRecovering)

        state.resetRecovery()
        #expect(!state.hasConnectedOnce)
        #expect(!state.isRecovering)
    }

    @Test func aRecoveredConnectionReportsRecoveryAndClearsRetryState() {
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let state = RemoteSessionConnectionController(reconnect: controller)
        _ = state.markConnected()
        _ = state.scheduleRecovery(after: "offline") {}

        #expect(state.markConnected())
        #expect(state.reconnectState == nil)
        #expect(state.hasConnectedOnce)
        #expect(!state.isRecovering)
    }

    @Test func firstUseHostKeyContinuesOnTheOriginalSSHConnection() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        var connectionCount = 0
        let services = MobileWorkspaceConnectionServices(
            makePTYChannel: {
                SSHPTYChannel(output: $0, exit: $1, shellIntegration: $2)
            },
            connectSSH: { _, request, _, _, _, _ in
                connectionCount += 1
                let configuration = request.configuration
                let observation = SSHHostKeyObservation(
                    hostname: configuration.host, port: configuration.port,
                    algorithm: .ed25519, fingerprint: "SHA256:first-use"
                )
                let authorizer = try #require(request.authorizeHostKey)
                guard
                    try await authorizer(
                        SSHHostKeyChallenge(
                            hostID: configuration.hostID,
                            observation: observation,
                            expectedHostKeys: configuration.expectedHostKeys
                        )
                    ) == .accept
                else { throw CancellationError() }
            },
            connectSFTP: { _, _, _ in throw SFTPError.notConnected },
            writeSSH: { _, _ in }
        )
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(
                hostID: host.id, title: host.name, kind: .ssh
            ),
            hosts: library, connectionServices: services
        )
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.hostKeyPrompt != nil })
        #expect(connectionCount == 1)
        workspace.trustHostKey()

        #expect(await eventually { workspace.connected })
        #expect(connectionCount == 1)
        #expect(library.knownHosts(for: host).map(\.fingerprint) == ["SHA256:first-use"])
    }

    private func connectionFixture() throws -> (TermindDomain.Host, HostLibraryModel) {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        return (host, library)
    }

    private func configureConnectionFixture(in app: MobileAppModel) throws -> TermindDomain.Host {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        app.library.upsert(host)
        app.library.trust(
            KnownHostEntry(
                hostname: host.host, port: host.port, algorithm: .ed25519,
                fingerprint: "SHA256:test"))
        return host
    }
}

@Suite @MainActor
struct MobileLiveActivitySchedulingTests {
    @Test func workspaceStateChangePublishesAValueSnapshot() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library, connectionServices: connections.services)
        let activities = MobileLiveActivityController(enabled: true)
        var receivedID: UUID?
        var receivedConnected = false
        workspace.didChangeState = {
            receivedID = $0.id
            receivedConnected = $0.connected
            activities.update([$0])
        }
        defer {
            workspace.didChangeState = nil
            workspace.disconnect()
            activities.update([])
        }

        workspace.connect()
        for _ in 0..<100 where !workspace.connected {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(workspace.connected)
        #expect(receivedID == workspace.id)
        #expect(receivedConnected)
    }
}

@Suite(.requiresKeyWindow, .serialized) @MainActor
struct MobileWorkspaceNavigationRenderingTests {
    @Test func padWorkspaceDetailsShowTopTabsAndLeadingSwitcherButHideCompactBottomTabs() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(inMemory: true, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        let sshID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let sftpID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(sshID)
        try await withHostedView(MobileRootView(app: app, scene: scene)) { controller in
            let tabs = try #require(descendant(of: UITabBarController.self, in: controller))
            for id in [sshID, sftpID] {
                scene.selectWorkspace(id)
                let workspace = try #require(app.workspaces.first { $0.id == id })
                let navigation = try #require(
                    await navigationController(titled: workspace.descriptor.title, in: controller))
                let detail = try #require(navigation.topViewController)
                for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact, .regular] {
                    controller.traitOverrides.horizontalSizeClass = sizeClass
                    tabs.sidebar.isHidden = true
                    try await Task.sleep(for: .milliseconds(700))
                    #expect(tabs.isTabBarHidden == (sizeClass == .compact))
                    #expect(navigation.topViewController === detail)
                    let leading =
                        detail.navigationItem.leadingItemGroups.flatMap(\.barButtonItems)
                        + (detail.navigationItem.leftBarButtonItems ?? [])
                    #expect(leading.contains { $0.menu != nil } == (sizeClass == .regular))
                    if let image = renderedPNGData(of: controller) {
                        Attachment.record(
                            image, named: "workspace-tabs-\(workspace.descriptor.kind)-\(sizeClass.rawValue).png")
                    }
                }
                tabs.sidebar.isHidden = false
                try await Task.sleep(for: .milliseconds(700))
                let search = try #require(detail.navigationItem.searchController)
                #expect(!search.isActive)
                if #available(iOS 26.0, *) {
                    #expect(detail.navigationItem.preferredSearchBarPlacement == .integratedButton)
                }
                #expect(!workspace.find.isPresented)
                if let image = renderedPNGData(of: controller) {
                    Attachment.record(image, named: "workspace-sidebar-search-\(workspace.descriptor.kind).png")
                }
            }
        }
    }

    @Test func crossDestinationExecutionBuildsTheWorkspaceDetailInThePadRoot() async throws {
        let connections = MobileSFTPConnectionBox(clients: [])
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        let host = try configureConnectionFixture(in: app)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        let snippet = Snippet(title: "Status", body: "uptime")

        scene.execute(snippet, on: [host.id])
        let workspace = try #require(app.workspaces.first)
        defer { app.testWorkspaceSession.closeAll() }
        #expect(app.testWorkspaceSession.renameWorkspace(workspace.id, to: "Snippet Workspace"))
        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceID == nil)

        try await withHostedView(
            MobileRootView(app: app, scene: scene)
                .environment(\.horizontalSizeClass, .regular)
        ) { controller in
            let navigation = try #require(
                await navigationController(titled: "Snippet Workspace", in: controller)
            )
            let detail = try #require(navigation.topViewController)
            #expect(scene.workspaceID == workspace.id)
            #expect(descendant(of: MobileTerminalView.self, in: detail.view) != nil)
        }
    }

    @Test func switchingFromSFTPRebuildsSSHContentAndConnectionJourney() async throws {
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        let host = try configureConnectionFixture(in: app)
        let sftpID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        let sshID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let journeyID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        defer { app.testWorkspaceSession.closeAll() }

        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        try await Task.sleep(for: .milliseconds(700))
        #expect(app.testWorkspaceSession.renameWorkspace(sftpID, to: "SFTP Workspace"))
        #expect(app.testWorkspaceSession.renameWorkspace(sshID, to: "SSH Workspace"))
        #expect(app.testWorkspaceSession.renameWorkspace(journeyID, to: "SSH Journey"))

        let journeyWorkspace = try #require(app.workspaces.first(where: { $0.id == journeyID }))
        journeyWorkspace.disconnect()
        journeyWorkspace.journey.begin(
            host: host,
            route: app.library.route(for: host),
            purpose: .sshSession,
            username: app.library.identity(for: host)?.username
        )
        journeyWorkspace.journey.fail("Network unavailable", at: host.id)

        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(sftpID)
        try await withHostedView(MobileRootView(app: app, scene: scene)) { controller in
            var navigation = try #require(
                await navigationController(titled: "SFTP Workspace", in: controller)
            )
            var detail = try #require(navigation.topViewController)
            #expect(!detail.navigationItem.hidesBackButton)
            #expect(descendant(of: MobileTerminalView.self, in: detail.view) == nil)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try #require(detail.navigationItem.searchController).isActive == false)
            if #available(iOS 26.0, *) {
                #expect(detail.navigationItem.preferredSearchBarPlacement == .integratedButton)
            }
            if let image = renderedPNGData(of: controller) {
                Attachment.record(image, named: "workspace-sftp-toolbar.png")
            }

            scene.selectWorkspace(sshID)
            navigation = try #require(
                await navigationController(titled: "SSH Workspace", in: controller)
            )
            detail = try #require(navigation.topViewController)
            let terminal = try #require(descendant(of: MobileTerminalView.self, in: detail.view))
            #expect(!detail.navigationItem.hidesBackButton)
            #expect(terminal.window != nil)
            #expect(terminal.bounds.width > 0)
            #expect(terminal.bounds.height > 0)
            try await Task.sleep(for: .milliseconds(500))
            #expect(try #require(detail.navigationItem.searchController).isActive == false)
            if #available(iOS 26.0, *) {
                #expect(detail.navigationItem.preferredSearchBarPlacement == .integratedButton)
            }
            if let image = renderedPNGData(of: controller) {
                Attachment.record(image, named: "workspace-ssh-toolbar.png")
            }

            scene.selectWorkspace(sftpID)
            _ = try #require(await navigationController(titled: "SFTP Workspace", in: controller))
            scene.selectWorkspace(journeyID)
            navigation = try #require(
                await navigationController(titled: "SSH Journey", in: controller)
            )
            detail = try #require(navigation.topViewController)
            #expect(!detail.navigationItem.hidesBackButton)

            scene.selectWorkspace(sshID)
            _ = try #require(await navigationController(titled: "SSH Workspace", in: controller))
            scene.selectWorkspace(sftpID)
            _ = try #require(await navigationController(titled: "SFTP Workspace", in: controller))
            scene.closeWorkspace(sftpID)
            _ = try #require(await navigationController(titled: "Workspaces", in: controller))
            #expect(scene.workspaceID == nil)
        }
    }

    @Test func resizingKeepsWorkspaceDetailsWithoutReconnecting() async throws {
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(inMemory: true, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        let sshID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        let sftpID = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        #expect(app.testWorkspaceSession.renameWorkspace(sshID, to: "Resize SSH"))
        #expect(app.testWorkspaceSession.renameWorkspace(sftpID, to: "Resize SFTP"))
        let ssh = try #require(app.workspaces.first { $0.id == sshID })
        let sftp = try #require(app.workspaces.first { $0.id == sftpID })
        let terminal = ssh.terminal
        let browser = sftp.sftpChannel
        browser.query = "Retained session filter"
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(sshID)
        let regions = MobileRegionTestState()
        try await withHostedView(
            MobileRegionTestHost(state: regions) { MobileRootView(app: app, scene: scene) }
        ) { controller in
            _ = try #require(await navigationController(titled: "Resize SSH", in: controller))
            for id in [sshID, sftpID] {
                scene.selectWorkspace(id)
                let title = id == sshID ? "Resize SSH" : "Resize SFTP"
                let navigation = try #require(await navigationController(titled: title, in: controller))
                let detail = navigation.topViewController
                let nativeTerminal = detail.flatMap { descendant(of: MobileTerminalView.self, in: $0.view) }
                for sizeClass: UIUserInterfaceSizeClass in [.regular, .compact, .regular, .compact] {
                    controller.traitOverrides.horizontalSizeClass = sizeClass
                    try await Task.sleep(for: .milliseconds(300))
                    #expect(scene.workspaceID == id)
                    let resizedNavigation = try #require(await navigationController(titled: title, in: controller))
                    #expect(resizedNavigation === navigation)
                    #expect(navigation.topViewController === detail)
                    #expect(ssh.connected && sftp.connected)
                    #expect(ssh.terminal === terminal)
                    #expect(sftp.sftpChannel === browser)
                    #expect(browser.query == "Retained session filter")
                    #expect(connections.sshConnectCount == 1)
                    #expect(connections.connectCount == 1)
                }
                for region in [
                    MobileReservedRegion(kind: .division, frame: CGRect(x: 0, y: 250, width: 2000, height: 32)),
                    MobileReservedRegion(kind: .division, frame: CGRect(x: 160, y: 0, width: 32, height: 2000)),
                    MobileReservedRegion(kind: .occlusion, frame: CGRect(x: 0, y: 0, width: 50, height: 40)),
                    MobileReservedRegion(kind: .division, frame: .zero, isActive: false),
                ] {
                    regions.regions = [region]
                    try await Task.sleep(for: .milliseconds(400))
                    #expect(navigation.topViewController === detail)
                    #expect(ssh.terminal === terminal)
                    #expect(sftp.sftpChannel === browser)
                    #expect(ssh.connected && sftp.connected)
                    #expect(connections.sshConnectCount == 1)
                    #expect(connections.connectCount == 1)
                    if let nativeTerminal, let detail {
                        #expect(descendant(of: MobileTerminalView.self, in: detail.view) === nativeTerminal)
                        #expect(nativeTerminal.bounds.width > 0 && nativeTerminal.bounds.height > 0)
                    }
                }
            }
        }
    }

    @Test(arguments: [DynamicTypeSize.large, .accessibility3])
    func sftpLongPathsFitNarrowAndWideContainers(typeSize: DynamicTypeSize) async throws {
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(inMemory: true, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        let id = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .sftp))
        defer { app.testWorkspaceSession.closeAll() }
        let workspace = try #require(app.workspaces.first { $0.id == id })
        #expect(await eventually { workspace.connected })
        let path = "/srv/projects/production-environment/很长的服务器配置目录/application-configuration"
        await workspace.sftpChannel.openDirectory(path)
        let scene = MobileSceneModel(app: app, sessionID: "test")
        scene.selectWorkspace(id)
        try await withHostedView(
            MobileRootView(app: app, scene: scene)
                .environment(\.horizontalSizeClass, .compact)
                .environment(\.dynamicTypeSize, typeSize)
        ) { controller in
            _ = try #require(await navigationController(titled: workspace.descriptor.title, in: controller))
            for width: CGFloat in [390, 844] {
                controller.view.frame.size = CGSize(width: width, height: 800)
                controller.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                #expect(workspace.sftpChannel.path == path)
                #expect(connections.connectCount == 1)
                let image = try #require(renderedPNGData(of: controller))
                Attachment.record(image, named: "sftp-long-path-\(Int(width))-\(typeSize).png")
            }
        }
    }

    private func configureConnectionFixture(in app: MobileAppModel) throws -> TermindDomain.Host {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        app.library.upsert(host)
        app.library.trust(
            KnownHostEntry(
                hostname: host.host,
                port: host.port,
                algorithm: .ed25519,
                fingerprint: "SHA256:test"
            )
        )
        return host
    }

    private func withHostedView<Content: View>(
        _ content: Content,
        check: (UIViewController) async throws -> Void
    ) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: content)
        window.rootViewController = controller
        window.windowLevel = .alert + 2
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(700))
        try await check(controller)
    }

    private func navigationController(
        titled title: String,
        in controller: UIViewController
    ) async -> UINavigationController? {
        for _ in 0..<50 {
            if let navigation = descendants(of: UINavigationController.self, in: controller).first(where: {
                $0.topViewController?.navigationItem.title == title
            }) {
                return navigation
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func renderedPNGData(of controller: UIViewController) -> Data? {
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        return image.pngData()
    }
}

@MainActor
private final class MobileSFTPConnectionBox {
    var connectionFailure: (@Sendable (String) -> Void)?
    private var clients: [any SFTPClientProtocol]
    private let progressEvents: [SSHRouteEvent]
    private(set) var connectCount = 0
    private(set) var didReceiveProgressHandler = false
    private(set) var sshConnectCount = 0
    private(set) var sshExitHandlers: [SSHPTYChannel.ExitHandler] = []

    init(
        clients: [any SFTPClientProtocol],
        progressEvents: [SSHRouteEvent] = []
    ) {
        self.clients = clients
        self.progressEvents = progressEvents
    }

    var services: MobileWorkspaceConnectionServices {
        MobileWorkspaceConnectionServices(
            makePTYChannel: { [self] output, exit, shellIntegration in
                sshExitHandlers.append(exit)
                return SSHPTYChannel(output: output, exit: exit, shellIntegration: shellIntegration)
            },
            connectSSH: { [self] _, _, _, _, _, _ in sshConnectCount += 1 },
            connectSFTP: { [self] _, progress, connectionFailure in
                guard !clients.isEmpty else { throw SFTPError.notConnected }
                self.connectionFailure = connectionFailure
                self.connectCount += 1
                self.didReceiveProgressHandler = progress != nil
                for event in progressEvents { progress?(event) }
                return self.clients.removeFirst()
            },
            writeSSH: { session, data in await session.write(data) })
    }
}

@MainActor
private final class MobileTestBackgroundTaskManager: MobileBackgroundTaskManaging {
    private var expiration: (@MainActor () -> Void)?
    private(set) var beginCount = 0

    func begin(expiration: @escaping @MainActor () -> Void) {
        beginCount += 1
        self.expiration = expiration
    }

    func finish() {
        expiration = nil
    }

    func expire() {
        let action = expiration
        expiration = nil
        action?()
    }
}

private actor MobileOperationFailingSFTPClient: SFTPClientProtocol {
    private var listCount = 0

    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home/test" }
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        defer { listCount += 1 }
        if listCount > 0 { throw SFTPError.operation("Permission denied") }
        return []
    }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}

private final class MobileFailingSecretStore: SecretStoring, @unchecked Sendable {
    let message: String

    init(message: String) { self.message = message }

    func string(for account: String, storage: PasswordStorage) throws -> String? { nil }
    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {
        throw TermindSSHError.library(message)
    }
    func keyCredential(for account: String, storage: KeyStorage) throws -> StoredSSHKeyCredential? { nil }
    func setKeyCredential(_ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage) throws {}
    func removePassword(_ account: String, storage: PasswordStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}

private actor MobileTestSFTPClient: SFTPClientProtocol {
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home/test" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}

@Suite struct WorkspaceActivityRoutingTests {
    @Test func activityBoundsItsPayloadAndKeepsTheFocusedSessionVisible() throws {
        let sessions = (0..<12).map { index in
            WorkspaceActivityAttributes.Session(
                id: UUID(), title: String(repeating: "服务器🖥️", count: 100),
                kind: "ssh", connected: index < 3)
        }
        let focused = sessions[10].id
        let state = WorkspaceActivityAttributes.ContentState.snapshot(sessions, focusedID: focused)
        #expect(state.workspaceCount == 12)
        #expect(state.connectedCount == 3)
        #expect(WorkspaceActivityAttributes.ContentState.maximumPresentedSessionCount == 6)
        #expect(state.sessions.count == 6)
        #expect(state.sessions.first?.id == focused)
        #expect(state.workspaceCount > state.sessions.count)
        #expect(WorkspaceActivityAttributes.workspaceID(from: state.destinationURL) == focused)
        #expect(try JSONEncoder().encode(state).count < 3500)
    }

    @Test func activityDecodesLegacyStatesWithSixSessions() throws {
        let sessions = (0..<6).map { index in
            WorkspaceActivityAttributes.Session(
                id: UUID(), title: "Workspace \(index)", kind: "ssh", connected: index < 2)
        }
        let legacyState = WorkspaceActivityAttributes.ContentState(
            workspaceCount: sessions.count, connectedCount: 2, sessions: sessions, focusedWorkspaceID: nil)

        let restored = try JSONDecoder().decode(
            WorkspaceActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(legacyState))

        #expect(restored.sessions.count == 6)
        #expect(restored.workspaceCount == 6)
        #expect(restored.connectedCount == 2)
    }

    @Test func payloadBudgetRetainsWholeFocusedIdentityAndNeverPutsOwnershipInLinks() throws {
        let ownership = UUID()
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "$1", name: "Server", identity: Data(repeating: 42, count: 512)),
            hostID: UUID(), endpoint: "example.invalid:22", username: "u", ownershipToken: ownership)
        let encoded = try JSONEncoder().encode(reference)
        let sessions = (0..<6).map { _ in
            let id = UUID()
            return WorkspaceActivityAttributes.Session(
                id: id, title: "Server", kind: "ssh", connected: false,
                recovery: .init(sourceWorkspaceID: id, hostID: reference.hostID, kind: "ssh", remoteSession: encoded))
        }
        let focused = sessions[4]
        let state = WorkspaceActivityAttributes.ContentState.snapshot(sessions, focusedID: focused.id)
        #expect(!state.sessions.isEmpty && state.sessions.count < sessions.count)
        #expect(state.sessions.first?.id == focused.id)
        #expect(try JSONEncoder().encode(state).count <= 3500)
        let retained = try #require(state.sessions.first?.recovery?.remoteSession)
        #expect(try JSONDecoder().decode(RemoteSessionReference.self, from: retained) == reference)
        #expect(!state.destinationURL.absoluteString.contains(ownership.uuidString))
        #expect(WorkspaceActivityAttributes.recovery(from: state.destinationURL)?.remoteSession == nil)
    }

    @Test func aggregateActivityOpensOnlyTheWorkspaceList() throws {
        #expect(WorkspaceActivityAttributes.accepts(WorkspaceActivityAttributes.destinationURL))
        for value in ["https://workspaces", "termind://workspaces/extra", "termind://workspaces?command=ls"] {
            #expect(!WorkspaceActivityAttributes.accepts(try #require(URL(string: value))))
        }
    }

    @Test func acceptsOnlyWorkspaceLinks() throws {
        let id = UUID()
        #expect(
            WorkspaceActivityAttributes.workspaceID(from: try #require(URL(string: "termind://workspace/\(id)"))) == id)
        for value in [
            "https://workspace/\(id)", "termind://workspace/not-an-id", "termind://workspace/\(id)/extra",
            "termind://workspace/\(id)?command=ls",
        ] {
            #expect(WorkspaceActivityAttributes.workspaceID(from: try #require(URL(string: value))) == nil)
        }
    }

    @Test func workspaceDropTargetInstallsItsNativeInteractionOnTheWindow() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1_024, height: 768))
        var targeted: [Bool] = []
        let coordinator = MobileWindowDropTarget.Coordinator(
            isEnabled: true,
            targeted: { targeted.append($0) },
            receive: { !$0.isEmpty }
        )

        let region = UIView(frame: window.bounds)
        window.addSubview(region)
        coordinator.install(in: region)

        #expect(window.interactions.contains { $0 is UIDropInteraction })
        coordinator.isEnabled = false
        #expect(!targeted.contains(true))
        coordinator.uninstall()
        #expect(!window.interactions.contains { $0 is UIDropInteraction })
    }
}

@Suite struct WorkspaceHostIconTests {
    @Test(arguments: HostGeneralIcon.allCases)
    @MainActor func generalArtworkIsAvailableOnMobile(icon: HostGeneralIcon) {
        #expect(UIImage(systemName: icon.systemImageName) != nil)
    }

    @Test func activityPreservesGeneralArtworkAndReadsLegacyPayloads() throws {
        let session = WorkspaceActivityAttributes.Session(
            id: UUID(), title: "Cloud", kind: "ssh", connected: true, iconSystemName: "cloud")
        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(WorkspaceActivityAttributes.Session.self, from: data)
        #expect(restored.iconSystemName == "cloud")
        #expect(restored.iconAsset == nil)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "iconSystemName")
        legacy["iconAsset"] = "HostOS-macos"
        let oldSession = try JSONDecoder().decode(
            WorkspaceActivityAttributes.Session.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(oldSession.iconSystemName == nil)
        #expect(oldSession.iconAsset == "HostOS-macos")
    }

    @Test @MainActor func operatingSystemArtworkIsBundledOnMobile() {
        #expect(HostIconCatalog.bundled.selectableEntries.first?.title == "AlmaLinux")
        #expect(HostIconCatalog.bundled.selectableEntries.last?.title == "Zorin")
        for entry in HostIconCatalog.bundled.entries {
            #expect(UIImage(named: entry.asset) != nil, Comment(rawValue: entry.asset))
        }
    }
    @Test func usesTheSameDistributionMatchAsTheHostList() throws {
        let catalog = try JSONDecoder().decode(
            HostIconCatalog.self,
            from: Data(
                #"{"entries":[{"id":"ubuntu","title":"Ubuntu","asset":"LinuxDistro-ubuntu","ids":["ubuntu"],"hex":"E95420"},{"id":"debian","title":"Debian","asset":"LinuxDistro-debian","ids":["debian"],"hex":"A81D33"}]}"#
                    .utf8))
        let ubuntu = try #require(DetectedDistribution(id: "ubuntu", likeIDs: ["debian"]))
        #expect(catalog.entry(matching: ubuntu)?.asset == "LinuxDistro-ubuntu")
        let derivative = try #require(DetectedDistribution(id: "custom", likeIDs: ["debian"]))
        #expect(catalog.entry(matching: derivative)?.asset == "LinuxDistro-debian")
        #expect(catalog.entry(matching: try #require(DetectedDistribution(id: "unknown"))) == nil)
    }

    @Test func activityPreservesSystemArtworkAndSessionDestination() throws {
        let id = UUID()
        let session = WorkspaceActivityAttributes.Session(
            id: id, title: "Production", kind: "ssh",
            connected: true, iconAsset: "LinuxDistro-ubuntu")
        let state = WorkspaceActivityAttributes.ContentState.snapshot([session], focusedID: id)
        let restored = try JSONDecoder().decode(
            WorkspaceActivityAttributes.ContentState.self,
            from: JSONEncoder().encode(state))
        #expect(restored.sessions.first?.iconAsset == "LinuxDistro-ubuntu")
        #expect(WorkspaceActivityAttributes.workspaceID(from: restored.destinationURL) == id)
    }
}

@Suite @MainActor
struct MobileWorkspaceRestorationTests {
    @Test func relaunchIsEmptyAndRetiresOnlyWorkspaceKeys() throws {
        let name = "WorkspaceRetirement.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("old-snapshot".utf8), forKey: MobileWorkspaceStore.key)
        defaults.set(Data("old-closed".utf8), forKey: MobileWorkspaceStore.recentlyClosedKey)
        defaults.set("retained", forKey: "unrelated.setting")
        let app = try MobileAppModel(dependencies: .testing(defaults: defaults))
        #expect(app.workspaces.isEmpty)
        #expect(app.testWorkspaceSession.orderedWorkspaceItems.isEmpty)
        #expect(app.closedWorkspaceRecords.isEmpty)
        #expect(defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(defaults.object(forKey: MobileWorkspaceStore.recentlyClosedKey) == nil)
        #expect(defaults.string(forKey: "unrelated.setting") == "retained")
        let host = TermindDomain.Host(name: "Saved", host: "example.invalid")
        app.library.upsert(host)
        let id = try #require(app.testWorkspaceSession.open(hostID: host.id, kind: .ssh))
        app.testWorkspaceSession.close(id)
        #expect(app.closedWorkspaceRecords.count == 1)
        #expect(defaults.object(forKey: MobileWorkspaceStore.key) == nil)
        #expect(defaults.object(forKey: MobileWorkspaceStore.recentlyClosedKey) == nil)
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = app.container
        let next = try MobileAppModel(dependencies: dependencies)
        #expect(next.library.host(host.id) != nil)
        #expect(next.workspaces.isEmpty)
        #expect(next.closedWorkspaceRecords.isEmpty)
    }

    @Test func legacyActivityLinksOpenOnlyExistingWorkspacesAndNeverRebuildClosedOnes() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Saved", host: "example.invalid")
        app.library.upsert(host)
        let first = MobileSceneModel(app: app, sessionID: "first")
        let second = MobileSceneModel(app: app, sessionID: "second")
        let source = try #require(first.workspaceSession.open(hostID: host.id, kind: .ssh))
        let url = try #require(URL(string: "termind://workspace/\(source)?v=1&host=\(host.id)&kind=ssh"))
        first.open(url)
        first.activatePendingWorkspace()
        #expect(first.activeWorkspace?.id == source)
        #expect(first.activeWorkspace?.sessionPersistence.requiresSelection == false)
        var activated: [UUID] = []
        app.activateWorkspaceSession = { owner, id, _ in
            #expect(owner == "first")
            activated.append(id)
        }
        second.open(url)
        first.open(url)
        #expect(app.workspaces.count == 1)
        #expect(activated == [source])
        first.workspaceSession.closeAll()
        first.open(url)
        second.open(url)
        #expect(first.isWorkspaceUnavailable && second.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
    }

    @Test func oldAndDeletedHostLinksCannotGuessAConnection() throws {
        let app = try MobileAppModel(inMemory: true)
        let scene = MobileSceneModel(app: app, sessionID: "first")
        let source = UUID()
        scene.open(WorkspaceActivityAttributes.destinationURL(for: source))
        #expect(scene.isWorkspaceUnavailable)
        let session = WorkspaceActivityAttributes.Session(
            id: source, title: "Deleted", kind: "ssh", connected: false,
            recovery: .init(sourceWorkspaceID: source, hostID: UUID(), kind: "ssh"))
        scene.open(session.destinationURL)
        #expect(scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
    }

    @Test func unsupportedAndCommandBearingActivityLinksShowAnErrorWithoutRebuilding() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Saved", host: "example.invalid")
        app.library.upsert(host)
        let scene = MobileSceneModel(app: app, sessionID: "first")
        let source = UUID()
        for query in [
            "v=2&host=\(host.id)&kind=ssh",
            "v=1&host=\(host.id)&kind=ssh&command=ls",
            "v=1&host=\(host.id)&kind=unknown",
        ] {
            scene.isWorkspaceUnavailable = false
            scene.open(try #require(URL(string: "termind://workspace/\(source)?\(query)")))
            #expect(scene.isWorkspaceUnavailable)
            #expect(app.workspaces.isEmpty)
        }
    }
}

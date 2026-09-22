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

    @Test func scenesCanUseTheSameAppRepository() throws {
        let repository = InMemoryHostRepository()
        let app = try MobileAppModel(hosts: repository)
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        try repository.upsertHost(host)
        #expect(try app.hosts.snapshot().value.hosts == [host])
    }

    @Test func assistantNavigationAndDraftsAreSceneLocalWhileConversationsAreShared() throws {
        let app = try MobileAppModel(inMemory: true)
        let first = MobileSceneModel(app: app)
        let second = MobileSceneModel(app: app)
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

    @Test func historyModelsUseTheSharedSwiftDataContainer() throws {
        let app = try MobileAppModel(inMemory: true)
        let hostID = UUID()
        app.commandHistory.record("echo persisted", for: hostID)
        app.sftpHistory.record(kind: .directory, path: "/srv/app", for: hostID)

        let commands = CommandHistoryModel(
            repository: SwiftDataCommandHistoryRepository(context: ModelContext(app.container))
        )
        let files = SFTPHistoryModel(
            repository: SwiftDataSFTPHistoryRepository(context: ModelContext(app.container))
        )

        #expect(commands.entries(for: hostID).map(\.command) == ["echo persisted"])
        #expect(files.entries(for: hostID).map(\.path) == ["/srv/app"])
    }

    @Test func clearingRecentsPreservesCommandAndFileHistory() throws {
        let app = try MobileAppModel(inMemory: true)
        defer { app.outbox.stop() }
        let host = TermindDomain.Host(name: "Recent", host: "recent.example.invalid")
        app.library.upsert(host)
        _ = app.connectionHistory.record(kind: .ssh, for: host.id)
        app.commandHistory.record("pwd", for: host.id)
        app.sftpHistory.record(kind: .directory, path: "/srv", for: host.id)

        app.connectionHistory.clear(for: host.id)

        #expect(app.connectionHistory.entries(for: host.id).isEmpty)
        #expect(app.commandHistory.entries(for: host.id).map(\.command) == ["pwd"])
        #expect(app.sftpHistory.entries(for: host.id).map(\.path) == ["/srv"])
    }
}

@Suite @MainActor
struct MobileWorkspaceTests {
    @Test func externalConnectionWorkspaceIsEphemeralAndDoesNotTouchVault() throws {
        let app = try MobileAppModel(inMemory: true)
        let request = try RemoteConnectionURLParser.parse(
            #require(URL(string: "ssh://deploy@example.invalid:2222")))
        let id = app.openExternalConnection(request)
        let workspace = try #require(app.workspaces.first { $0.id == id })

        #expect(workspace.isExternalTemporaryConnection)
        #expect(workspace.descriptor.title == "example.invalid")
        #expect(app.savedWorkspaceDescriptors.isEmpty)
        #expect(app.library.hosts.isEmpty)
        #expect(app.orderedWorkspaceItems.map(\.id) == [id])
        #expect(app.orderedWorkspaceItems.first?.loginAddress == "deploy@example.invalid:2222")

        let savedHost = TermindDomain.Host(name: "Saved", host: "saved.example.invalid")
        app.library.upsert(savedHost)
        let savedID = try #require(app.open(hostID: savedHost.id, kind: .ssh))
        #expect(app.orderedWorkspaceItems.map(\.id) == [id, savedID])

        app.close(id)
        #expect(app.orderedWorkspaceItems.map(\.id) == [savedID])
        app.close(savedID)
        #expect(app.orderedWorkspaceItems.isEmpty)
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
        defer { app.closeAll() }

        let firstID = try #require(app.open(hostID: host.id, kind: .ssh))
        let secondID = try #require(
            app.open(hostID: host.id, kind: .ssh, initialPath: "/srv/releases"))
        let thirdID = try #require(
            app.execute(Snippet(title: "Status", body: "uptime"), on: [host.id]).first)
        let sftpID = try #require(
            app.open(hostID: host.id, kind: .sftp, initialPath: "/srv/releases"))

        let first = try #require(app.workspaces.first { $0.id == firstID })
        let second = try #require(app.workspaces.first { $0.id == secondID })
        let third = try #require(app.workspaces.first { $0.id == thirdID })
        let sftp = try #require(app.workspaces.first { $0.id == sftpID })
        #expect(
            [first, second, third, sftp].map(\.descriptor.title)
                == ["Server", "Server (1)", "Server (2)", "Server (3)"])
        #expect(third.activitySession.title == "Server (2)")

        #expect(app.renameWorkspace(secondID, to: "Logs"))
        let fourthID = try #require(app.open(hostID: host.id, kind: .ssh))
        let fourth = try #require(app.workspaces.first { $0.id == fourthID })
        #expect(fourth.descriptor.title == "Server (4)")

        app.close(firstID)
        let recycledBaseID = try #require(app.open(hostID: host.id, kind: .ssh))
        let recycledBase = try #require(app.workspaces.first { $0.id == recycledBaseID })
        #expect(recycledBase.descriptor.title == "Server")
        #expect(second.descriptor.title == "Logs")
        #expect(third.descriptor.title == "Server (2)")
        #expect(fourth.descriptor.title == "Server (4)")

        app.close(secondID)
        let recycledOneID = try #require(app.open(hostID: host.id, kind: .ssh))
        let recycledOne = try #require(app.workspaces.first { $0.id == recycledOneID })
        #expect(recycledOne.descriptor.title == "Server (5)")

        #expect(app.workspaceSettings.setAutomaticRenaming(false))
        let unnumberedID = try #require(app.open(hostID: host.id, kind: .sftp))
        #expect(app.workspaces.first { $0.id == unnumberedID }?.descriptor.title == "Server")
    }

    @Test func hostNamesThatEndInNumbersDoNotConflictWithParenthesizedSuffixes() throws {
        let app = try MobileAppModel(inMemory: true)
        let server = TermindDomain.Host(name: "Server", host: "server.example")
        let serverOne = TermindDomain.Host(name: "Server 1", host: "server-one.example")
        app.library.upsert(server)
        app.library.upsert(serverOne)
        defer { app.closeAll() }

        let ids = [
            try #require(app.open(hostID: server.id, kind: .ssh)),
            try #require(app.open(hostID: serverOne.id, kind: .sftp)),
            try #require(app.open(hostID: server.id, kind: .sftp)),
            try #require(app.open(hostID: serverOne.id, kind: .ssh)),
        ]
        #expect(
            ids.compactMap { id in app.workspaces.first { $0.id == id }?.descriptor.title }
                == ["Server", "Server 1", "Server (1)", "Server 1 (1)"])
    }

    @Test func closeAllDisconnectsAndRemovesEveryWorkspaceAndIsRepeatable() throws {
        let app = try MobileAppModel(inMemory: true)
        let host = TermindDomain.Host(name: "Test", host: "example.invalid")
        app.library.upsert(host)
        _ = try #require(app.open(hostID: host.id, kind: .ssh))
        _ = try #require(app.open(hostID: host.id, kind: .sftp))
        let opened = app.workspaces

        app.closeAll()

        #expect(app.workspaces.isEmpty)
        #expect(opened.allSatisfy { !$0.connected && $0.status == String(localized: "Disconnected") })

        app.closeAll()
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
        let store = MobileWorkspaceStore(defaults: defaults)
        try store.save(descriptors)
        var dependencies = MobileAppDependencies.testing(defaults: defaults)
        dependencies.container = seed.container
        dependencies.workspaceStore = store
        let app = try MobileAppModel(dependencies: dependencies)
        let scene = MobileSceneModel(app: app)
        let kept = try #require(app.openWorkspace(descriptors[0].id))
        let opened = try #require(app.openWorkspace(descriptors[1].id))

        #expect(app.recentWorkspaces == [descriptors[2]])
        #expect(app.closableWorkspaceCount == 3)
        #expect(scene.canCloseMultipleWorkspaces)

        scene.closeOtherWorkspaces(than: kept.id)

        #expect(app.workspaces.map(\.id) == [kept.id])
        #expect(app.savedWorkspaceDescriptors == [kept.descriptor])
        #expect(app.recentWorkspaces.isEmpty)
        #expect(!opened.connected)
        #expect(opened.status == String(localized: "Disconnected"))
        #expect(try store.load() == [kept.descriptor])
        #expect(!scene.canCloseMultipleWorkspaces)
        app.closeAll()
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

    @Test func freeMetricsLimitCountsAllSelectionsAndDeduplicates() {
        let library = HostLibraryModel()
        let hosts = (0..<5).map { TermindDomain.Host(name: "Host \($0)", host: "example.invalid") }
        for host in hosts { library.upsert(host) }
        let metrics = MobileMetricsModel(
            preferences: MetricsPreferences(), hosts: library, services: .testing)
        metrics.pause()
        #expect(metrics.add(hosts[0].id, pro: false))
        #expect(metrics.add(hosts[0].id, pro: false))
        #expect(metrics.add(hosts[1].id, pro: false))
        #expect(metrics.add(hosts[2].id, pro: false))
        #expect(!metrics.add(hosts[3].id, pro: false))
        #expect(metrics.add(hosts[4].id, pro: true))
        #expect(metrics.selections.count == 4)
    }
}

@Suite
struct MobileTerminalShiftStateTests {
    @Test func controlShortcutsPreserveOrderAndKeyPresses() {
        #expect(MobileTerminalControlShortcut.allCases.map(\.label) == ["^C", "^I", "^S", "^Z"])
        #expect(
            MobileTerminalControlShortcut.allCases.map(\.keyPress)
                == [
                    TerminalKeyPress(.c, modifiers: .ctrl),
                    TerminalKeyPress(.i, modifiers: .ctrl),
                    TerminalKeyPress(.s, modifiers: .ctrl),
                    TerminalKeyPress(.z, modifiers: .ctrl),
                ])
    }

    @Test func armedShiftAppliesOnce() {
        var state = MobileTerminalShiftState()
        state.toggle(at: Date(timeIntervalSince1970: 1))
        #expect(state.activation == .armed)
        #expect(state.consumeForNextKey() == .shift)
        #expect(state.activation == .inactive)
        #expect(state.consumeForNextKey().isEmpty)
    }

    @Test func quickSecondTapLocksShiftUntilCancelled() {
        var state = MobileTerminalShiftState()
        state.toggle(at: Date(timeIntervalSince1970: 1))
        state.toggle(at: Date(timeIntervalSince1970: 1.2))
        #expect(state.activation == .locked)
        #expect(state.consumeForNextKey() == .shift)
        #expect(state.activation == .locked)
        state.toggle(at: Date(timeIntervalSince1970: 2))
        #expect(state.activation == .inactive)
    }

    @Test func slowSecondTapCancelsArmedShift() {
        var state = MobileTerminalShiftState()
        state.toggle(at: Date(timeIntervalSince1970: 1))
        state.toggle(at: Date(timeIntervalSince1970: 2))
        #expect(state.activation == .inactive)
    }
}

@Suite @MainActor
struct MobileWorkspaceConnectionRecoveryTests {
    @Test func sameDirectorySFTPStartupUsesTheOverrideAndOffersSSHOnlyWhileConnected() async throws {
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        let host = try configureConnectionFixture(in: app)
        let id = try #require(app.open(hostID: host.id, kind: .sftp, initialPath: "/srv/releases/"))
        let workspace = try #require(app.workspaces.first(where: { $0.id == id }))
        defer { app.close(id) }

        #expect(workspace.sameDirectoryLaunch == nil)
        #expect(await eventually { workspace.connected })
        #expect(workspace.sftpChannel.path == "/srv/releases")
        #expect(
            workspace.sameDirectoryLaunch
                == MobileWorkspaceDirectoryLaunch(hostID: host.id, kind: .ssh, path: "/srv/releases")
        )
        #expect(app.renameWorkspace(id, to: "  Release Files  "))
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
        _ = try #require(app.open(hostID: host.id, kind: .sftp))
        _ = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
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
        _ = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
        #expect(await eventually { app.workspaces.first?.connected == true })
        let sceneID = UUID()
        app.sceneChanged(sceneID, phase: .active)
        app.sceneChanged(sceneID, phase: .background)

        app.sceneChanged(sceneID, phase: .active)
        background.expire()

        #expect(app.workspaces.first?.connected == true)
        #expect(connections.connectCount == 1)
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
        let firstID = try #require(app.open(hostID: host.id, kind: .ssh))
        #expect(
            await eventually {
                app.workspaces.first(where: { $0.id == firstID })?.connected == true
                    && connections.sshExitHandlers.count == 1
            })

        let secondID = try #require(app.open(hostID: host.id, kind: .ssh))
        defer { app.closeAll() }
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

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

@Suite(.serialized) @MainActor
struct MobileWorkspaceNavigationRenderingTests {
    @Test func padWorkspaceDetailsShowTopTabsAndLeadingSwitcherButHideCompactBottomTabs() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let connections = MobileSFTPConnectionBox(clients: [MobileTestSFTPClient()])
        let app = try MobileAppModel(inMemory: true, workspaceConnectionServices: connections.services)
        let host = try configureConnectionFixture(in: app)
        let sshID = try #require(app.open(hostID: host.id, kind: .ssh))
        let sftpID = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        let scene = MobileSceneModel(app: app)
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
        let scene = MobileSceneModel(app: app)
        let snippet = Snippet(title: "Status", body: "uptime")

        scene.execute(snippet, on: [host.id])
        let workspace = try #require(app.workspaces.first)
        defer { app.closeAll() }
        #expect(app.renameWorkspace(workspace.id, to: "Snippet Workspace"))
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
        let sftpID = try #require(app.open(hostID: host.id, kind: .sftp))
        let sshID = try #require(app.open(hostID: host.id, kind: .ssh))
        let journeyID = try #require(app.open(hostID: host.id, kind: .ssh))
        defer { app.closeAll() }

        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        try await Task.sleep(for: .milliseconds(700))
        #expect(app.renameWorkspace(sftpID, to: "SFTP Workspace"))
        #expect(app.renameWorkspace(sshID, to: "SSH Workspace"))
        #expect(app.renameWorkspace(journeyID, to: "SSH Journey"))

        let journeyWorkspace = try #require(app.workspaces.first(where: { $0.id == journeyID }))
        journeyWorkspace.disconnect()
        journeyWorkspace.journey.begin(
            host: host,
            route: app.library.route(for: host),
            purpose: .sshSession,
            username: app.library.identity(for: host)?.username
        )
        journeyWorkspace.journey.fail("Network unavailable", at: host.id)

        let scene = MobileSceneModel(app: app)
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
            #expect(try #require(renderedPNGData(of: detail)).count > 10_000)

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
        let sshID = try #require(app.open(hostID: host.id, kind: .ssh))
        let sftpID = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
        #expect(await eventually { app.workspaces.allSatisfy(\.connected) })
        #expect(app.renameWorkspace(sshID, to: "Resize SSH"))
        #expect(app.renameWorkspace(sftpID, to: "Resize SFTP"))
        let ssh = try #require(app.workspaces.first { $0.id == sshID })
        let sftp = try #require(app.workspaces.first { $0.id == sftpID })
        let terminal = ssh.terminal
        let browser = sftp.sftpChannel
        browser.query = "Retained session filter"
        let scene = MobileSceneModel(app: app)
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
        let id = try #require(app.open(hostID: host.id, kind: .sftp))
        defer { app.closeAll() }
        let workspace = try #require(app.workspaces.first { $0.id == id })
        #expect(await eventually { workspace.connected })
        let path = "/srv/projects/production-environment/很长的服务器配置目录/application-configuration"
        await workspace.sftpChannel.openDirectory(path)
        let scene = MobileSceneModel(app: app)
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

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

    private func descendants<T: UIViewController>(
        of type: T.Type,
        in controller: UIViewController
    ) -> [T] {
        var pending = [controller]
        var visited = Set<ObjectIdentifier>()
        var results: [T] = []
        while let next = pending.popLast() {
            guard visited.insert(ObjectIdentifier(next)).inserted else { continue }
            if let result = next as? T { results.append(result) }
            pending.append(contentsOf: next.children)
            if let presented = next.presentedViewController { pending.append(presented) }
        }
        return results
    }

    private func descendant<T: UIViewController>(
        of type: T.Type,
        in controller: UIViewController
    ) -> T? {
        descendants(of: type, in: controller).first
    }

    private func descendant<T: UIView>(of type: T.Type, in view: UIView) -> T? {
        if let result = view as? T { return result }
        for subview in view.subviews {
            if let result = descendant(of: type, in: subview) { return result }
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

    func begin(expiration: @escaping @MainActor () -> Void) {
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
    @Test func usesTheSameDistributionMatchAsTheHostList() throws {
        let catalog = try JSONDecoder().decode(
            LinuxDistributionIconCatalog.self,
            from: Data(
                #"{"entries":[{"title":"Ubuntu","asset":"LinuxDistro-ubuntu","ids":["ubuntu"],"hex":"E95420"},{"title":"Debian","asset":"LinuxDistro-debian","ids":["debian"],"hex":"A81D33"}]}"#
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
    @Test func displayOrderDoesNotChangeWhenSavedWorkspacesOpenOrRename() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let descriptors = (0..<3).map {
            MobileWorkspaceDescriptor(hostID: host.id, title: "Saved \($0)", kind: .ssh)
        }
        try fixture.store().save(descriptors)
        let app = try fixture.makeApp()
        defer { app.closeAll() }

        #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id))
        _ = try #require(app.openWorkspace(descriptors[1].id))
        #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id))
        #expect(app.renameWorkspace(descriptors[1].id, to: "Opened"))
        #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id))
        #expect(app.orderedWorkspaceItems.map(\.descriptor.title) == ["Saved 0", "Opened", "Saved 2"])

        #expect(app.renameWorkspace(descriptors[0].id, to: "Still Dormant"))
        #expect(app.workspaces.map(\.id) == [descriptors[1].id])
        #expect(app.orderedWorkspaceItems.map(\.descriptor.title) == ["Still Dormant", "Opened", "Saved 2"])
        #expect(try fixture.store().load().map(\.title) == ["Still Dormant", "Opened", "Saved 2"])

        let appended = try #require(app.open(hostID: host.id, kind: .sftp))
        #expect(app.orderedWorkspaceItems.map(\.id) == descriptors.map(\.id) + [appended])
    }

    @Test func relaunchPreservesDescriptorsWithoutConnectingOrReplayingCommands() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = try fixture.makeApp()
        let host = try fixture.installHost(in: first)
        let sshID = try #require(first.open(hostID: host.id, kind: .ssh, initialPath: "/private/work"))
        let commandID = try #require(
            first.execute(Snippet(title: "Deploy", body: "echo never-replay"), on: [host.id]).first)
        _ = try #require(first.open(hostID: host.id, kind: .sftp, initialPath: "/private/files"))
        #expect(first.renameWorkspace(sshID, to: "Release Shell"))
        let expected = first.workspaces.map(\.descriptor)
        let historyCount = first.connectionHistory.entries().count
        let saved = try #require(fixture.defaults.data(forKey: MobileWorkspaceStore.key))
        #expect(!String(decoding: saved, as: UTF8.self).contains("never-replay"))
        #expect(!String(decoding: saved, as: UTF8.self).contains("/private"))
        // Retire process-owned transports without closing the saved entries.
        for workspace in first.workspaces { workspace.disconnect() }

        let relaunched = try fixture.makeApp()
        #expect(relaunched.workspaces.isEmpty)
        #expect(relaunched.recentWorkspaces == expected)
        #expect(relaunched.connectionHistory.entries().count == historyCount)
        let restoredCommand = try #require(relaunched.openWorkspace(commandID))
        #expect(restoredCommand.pendingInitialCommand == nil)
        #expect(restoredCommand.descriptor == expected[1])
        let newID = try #require(relaunched.open(hostID: host.id, kind: .ssh))
        #expect(relaunched.workspaces.first { $0.id == newID }?.descriptor.title == host.name)
        relaunched.closeAll()
    }

    @Test func selectingRestoredWorkspaceAcrossScenesConnectsOnlyItOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let original = try fixture.makeApp()
        let host = try fixture.installHost(in: original)
        let descriptors = [
            MobileWorkspaceDescriptor(hostID: host.id, title: "First", kind: .sftp),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Second", kind: .sftp),
        ]
        try fixture.store().save(descriptors)
        let app = try fixture.makeApp()
        try fixture.installPassword(in: app)
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)
        let otherScene = MobileSceneModel(app: app)
        app.sceneChanged(scene.id, phase: .active)
        #expect(fixture.connections.connectCount == 0)
        #expect(app.connectionHistory.entries().isEmpty)

        scene.open(descriptors[1].destinationURL)
        scene.activatePendingWorkspace()
        otherScene.open(descriptors[1].destinationURL)
        otherScene.activatePendingWorkspace()
        scene.open(descriptors[1].destinationURL)
        #expect(await eventually { app.workspaces[0].connected })
        #expect(fixture.connections.connectCount == 1)
        #expect(app.workspaces.map(\.descriptor) == [descriptors[1]])
        #expect(app.recentWorkspaces == [descriptors[0]])
        #expect(app.connectionHistory.entries().count == 1)
        #expect(scene.workspaceID == descriptors[1].id)
        #expect(otherScene.workspaceID == descriptors[1].id)

        app.sceneChanged(otherScene.id, phase: .background)
        app.sceneChanged(scene.id, phase: .background)
        fixture.background.expire()
        app.sceneChanged(scene.id, phase: .active)
        #expect(await eventually { fixture.connections.connectCount == 2 && app.workspaces[0].connected })
        #expect(app.workspaces.map(\.descriptor) == [descriptors[1]])
        #expect(app.recentWorkspaces == [descriptors[0]])
    }

    @Test func failedFirstOpenRequiresExplicitRetryInsteadOfRetryingOnSelection() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Server", kind: .sftp)
        try fixture.store().save([descriptor])
        var attempts = 0
        var services = fixture.connections.services
        services.connectSFTP = { _, _, _ in
            attempts += 1
            throw SFTPError.notConnected
        }
        let app = try fixture.makeApp(services: services)
        try fixture.installPassword(in: app)
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)
        scene.open(descriptor.destinationURL)
        scene.activatePendingWorkspace()
        #expect(await eventually { attempts == 1 && !app.workspaces[0].busy })
        scene.selectWorkspace(descriptor.id)
        scene.selectWorkspace(descriptor.id)
        #expect(attempts == 1)
        app.workspaces[0].connect()
        #expect(await eventually { attempts == 2 && !app.workspaces[0].busy })
    }

    @Test func closeHostDeletionAndCloseAllRemoveSavedEntries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let host = try fixture.installHost(in: app)
        let otherHost = TermindDomain.Host(name: "Other", host: "other.invalid")
        app.library.upsert(otherHost)
        let closedID = try #require(app.open(hostID: host.id, kind: .ssh))
        _ = try #require(app.open(hostID: host.id, kind: .sftp))
        let remainingID = try #require(app.open(hostID: otherHost.id, kind: .ssh))
        app.close(closedID)
        #expect(try !fixture.store().load().contains { $0.id == closedID })
        app.deleteHost(host.id)
        #expect(try fixture.store().load().map(\.id) == [remainingID])
        let relaunched = try fixture.makeApp()
        #expect(relaunched.workspaces.isEmpty)
        #expect(relaunched.recentWorkspaces.map(\.id) == [remainingID])
        let history = relaunched.connectionHistory.entries()
        #expect(MobileSceneModel(app: relaunched).canCloseAllWorkspaces)
        relaunched.closeAll()
        #expect(relaunched.connectionHistory.entries() == history)
        #expect(try fixture.store().load().isEmpty)
        #expect(try fixture.makeApp().workspaces.isEmpty)
        for workspace in app.workspaces { workspace.disconnect() }
    }

    @Test func normalSSHExitRemovesSavedEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let app = try fixture.makeApp()
        let host = try fixture.installHost(in: app)
        _ = try #require(app.open(hostID: host.id, kind: .ssh))
        defer { app.closeAll() }
        #expect(await eventually { app.workspaces.first?.connected == true })
        let exit = try #require(fixture.connections.sshExitHandlers.first)
        exit(.success(23))
        #expect(await eventually { app.workspaces.isEmpty })
        #expect(try fixture.store().load().isEmpty)
        #expect(try fixture.makeApp().workspaces.isEmpty)
    }

    @Test func missingHostsArePrunedWithoutRecreatingThem() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let valid = MobileWorkspaceDescriptor(hostID: host.id, title: "Present", kind: .ssh)
        let missing = MobileWorkspaceDescriptor(hostID: UUID(), title: "Removed", kind: .ssh)
        try fixture.store().save([missing, valid])
        let app = try fixture.makeApp()
        #expect(app.workspaces.isEmpty)
        #expect(app.recentWorkspaces == [valid])
        #expect(try fixture.store().load() == [valid])
        app.closeAll()
    }

    @Test(arguments: [Data("broken".utf8), Data(#"{"version":99,"workspaces":[]}"#.utf8)])
    func unreadableSnapshotSurvivesStartupAndLaterMutations(data: Data) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(data, forKey: MobileWorkspaceStore.key)
        let app = try fixture.makeApp()
        #expect(app.workspaces.isEmpty)
        #expect(app.error != nil)
        let host = try fixture.installHost(in: app)
        _ = try #require(app.open(hostID: host.id, kind: .ssh))
        app.closeAll()
        #expect(fixture.defaults.data(forKey: MobileWorkspaceStore.key) == data)
    }

    @Test func staleAndAggregateLinksDoNotRestoreAnyWorkspaces() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let descriptor = MobileWorkspaceDescriptor(hostID: host.id, title: "Server", kind: .ssh)
        try fixture.store().save([descriptor])
        let app = try fixture.makeApp()
        defer { app.closeAll() }
        let scene = MobileSceneModel(app: app)
        scene.open(WorkspaceActivityAttributes.destinationURL(for: UUID()))
        scene.activatePendingWorkspace()
        #expect(scene.selectedDestination == .workspaces)
        #expect(scene.workspaceID == nil)
        #expect(scene.isWorkspaceUnavailable)
        scene.open(WorkspaceActivityAttributes.destinationURL)
        scene.activatePendingWorkspace()
        #expect(scene.workspaceID == nil)
        #expect(!scene.isWorkspaceUnavailable)
        #expect(app.workspaces.isEmpty)
        #expect(app.recentWorkspaces == [descriptor])
        #expect(app.connectionHistory.entries().isEmpty)

        scene.selectedDestination = .vault
        scene.open(descriptor.destinationURL)
        scene.open(WorkspaceActivityAttributes.destinationURL)
        scene.activatePendingWorkspace()
        #expect(scene.workspaceID == nil)
        #expect(app.workspaces.map(\.id) == [descriptor.id])
        #expect(app.connectionHistory.entries().count == 1)
        app.close(descriptor.id)
        scene.selectWorkspace(descriptor.id)
        #expect(scene.isWorkspaceUnavailable)
    }

    @Test func mutationsPreserveRecentEntriesAndTheirOrderAcrossLaunches() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let descriptors = (0..<3).map {
            MobileWorkspaceDescriptor(hostID: host.id, title: "Saved \($0)", kind: .ssh)
        }
        try fixture.store().save(descriptors)
        let app = try fixture.makeApp()
        let restored = try #require(app.openWorkspace(descriptors[1].id))
        #expect(restored.descriptor == descriptors[1])
        #expect(app.renameWorkspace(restored.id, to: "Renamed"))
        let created = try #require(app.open(hostID: host.id, kind: .ssh))
        #expect(app.workspaces.last?.descriptor.title == host.name)
        app.close(descriptors[0].id)
        app.close(created)
        let expected = [restored.descriptor, descriptors[2]]
        #expect(try fixture.store().load() == expected)
        #expect(app.recentWorkspaces == [descriptors[2]])
        let relaunched = try fixture.makeApp()
        #expect(relaunched.recentWorkspaces == expected)
        let replacement = try #require(relaunched.open(hostID: host.id, kind: .ssh))
        #expect(relaunched.workspaces.first?.descriptor.title == host.name)
        relaunched.close(replacement)
        app.closeAll()
    }

    @Test(arguments: [false, true])
    func hostDeletionRemovesBothCurrentAndUnopenedEntries(remote: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let other = TermindDomain.Host(name: "Other", host: "other.invalid")
        seed.library.upsert(other)
        let descriptors = [
            MobileWorkspaceDescriptor(hostID: host.id, title: "Open", kind: .ssh),
            MobileWorkspaceDescriptor(hostID: host.id, title: "Recent", kind: .sftp),
            MobileWorkspaceDescriptor(hostID: other.id, title: "Retained", kind: .ssh),
        ]
        try fixture.store().save(descriptors)
        let app = try fixture.makeApp()
        _ = try #require(app.openWorkspace(descriptors[0].id))
        if remote {
            app.applyRemoteVault(.init(hosts: [other]), keys: [VaultRecordKey(kind: .host, id: host.id)])
        } else {
            app.deleteHost(host.id)
        }
        #expect(app.workspaces.isEmpty)
        #expect(app.recentWorkspaces == [descriptors[2]])
        #expect(try fixture.store().load() == [descriptors[2]])
        app.closeAll()
    }

    @Test func legacyMigrationAllowsCreateRenameCloseAndRelaunch() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let seed = try fixture.makeApp()
        let host = try fixture.installHost(in: seed)
        let id = UUID()
        let legacy = """
            [{"id":"\(id)","hostID":"\(host.id)","title":"Original","kind":"ssh"}]
            """
        fixture.defaults.set(Data(legacy.utf8), forKey: MobileWorkspaceStore.key)
        let app = try fixture.makeApp()
        #expect(app.error == nil)
        #expect(app.recentWorkspaces.map(\.id) == [id])
        _ = try #require(app.openWorkspace(id))
        #expect(app.renameWorkspace(id, to: "Renamed"))
        let created = try #require(app.open(hostID: host.id, kind: .ssh))
        app.close(created)
        let relaunched = try fixture.makeApp()
        #expect(relaunched.error == nil)
        #expect(relaunched.recentWorkspaces.map(\.title) == ["Renamed"])
        #expect(relaunched.recentWorkspaces.map(\.id) == [id])
        relaunched.closeAll()
        #expect(try fixture.makeApp().recentWorkspaces.isEmpty)
        for workspace in app.workspaces { workspace.disconnect() }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private final class Fixture {
        let suiteName = "termind.workspace-restoration-tests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let container: ModelContainer
        let identity = Identity(name: "Deploy", username: "deploy")
        let background = MobileTestBackgroundTaskManager()
        let connections = MobileSFTPConnectionBox(
            clients: [MobileTestSFTPClient(), MobileTestSFTPClient(), MobileTestSFTPClient()])

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suiteName))
            container = try TermindPersistence.makeContainer(inMemory: true)
        }

        func store() -> MobileWorkspaceStore { MobileWorkspaceStore(defaults: defaults) }
        func cleanUp() { defaults.removePersistentDomain(forName: suiteName) }

        func makeApp(services: MobileWorkspaceConnectionServices? = nil) throws -> MobileAppModel {
            var dependencies = MobileAppDependencies.testing(
                background: background, workspaceConnections: services ?? connections.services)
            dependencies.container = container
            dependencies.workspaceStore = store()
            return try MobileAppModel(dependencies: dependencies)
        }

        func installHost(in app: MobileAppModel) throws -> TermindDomain.Host {
            var host = TermindDomain.Host(name: "Server", host: "example.invalid")
            host.identityID = identity.id
            try installPassword(in: app)
            app.library.upsert(host)
            app.library.trust(
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test"))
            return host
        }

        func installPassword(in app: MobileAppModel) throws {
            try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        }
    }
}

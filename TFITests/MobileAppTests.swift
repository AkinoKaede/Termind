import Foundation
import GhosttyTerminal
import SwiftData
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
        #expect(features.registrations(on: .phoneTab).map(\.id) == [.vault, .workspaces, .assistant, .settings])
    }

    @Test func scenesCanUseTheSameAppRepository() throws {
        let repository = InMemoryHostRepository()
        let app = try MobileAppModel(hosts: repository)
        let host = TermindDomain.Host(name: "Example", host: "example.invalid")
        try repository.upsertHost(host)
        #expect(try app.hosts.snapshot().value.hosts == [host])
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
}

@Suite @MainActor
struct MobileWorkspaceTests {
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
        #expect(workspace.sftpSession.path == "/srv/releases")
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
        await workspace.sftpSession.openDirectory("/restricted")

        #expect(workspace.sftpSession.operationError == "Permission denied")
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
        await workspace.sftpSession.openDirectory("/srv/project")
        #expect(workspace.sftpSession.path == "/srv/project")

        let retiredConnectionFailure = connections.connectionFailure
        retiredConnectionFailure?("offline")
        retiredConnectionFailure?("duplicate offline callback")
        #expect(await eventually { workspace.reconnectState?.attempt == 1 })
        #expect(workspace.journey.mode == .reconnection)
        #expect(workspace.operationError == nil)
        workspace.retryReconnectNow()

        #expect(await eventually { workspace.connected })
        #expect(workspace.sftpSession.path == "/srv/project")
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
        #expect(workspace.journey.purpose == .sftpSession)
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
            makeSSHSession: {
                SSHSessionActor(output: $0, exit: $1, shellIntegration: $2)
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

@MainActor
private final class MobileSFTPConnectionBox {
    var connectionFailure: (@Sendable (String) -> Void)?
    private var clients: [any SFTPClientProtocol]
    private let progressEvents: [SSHRouteEvent]
    private(set) var connectCount = 0
    private(set) var didReceiveProgressHandler = false
    private(set) var sshConnectCount = 0
    private(set) var sshExitHandlers: [SSHSessionActor.ExitHandler] = []

    init(
        clients: [any SFTPClientProtocol],
        progressEvents: [SSHRouteEvent] = []
    ) {
        self.clients = clients
        self.progressEvents = progressEvents
    }

    var services: MobileWorkspaceConnectionServices {
        MobileWorkspaceConnectionServices(
            makeSSHSession: { [self] output, exit, shellIntegration in
                sshExitHandlers.append(exit)
                return SSHSessionActor(output: output, exit: exit, shellIntegration: shellIntegration)
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

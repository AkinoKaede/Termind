import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UniformTypeIdentifiers

import struct TermindDomain.Host

@testable import TermindIOS

@MainActor
private final class MobileCommandGeneratorStub: CommandGenerating {
    var command: String
    var delay: Duration?
    private(set) var contexts: [CommandGeneratorContext] = []

    init(command: String, delay: Duration? = nil) {
        self.command = command
        self.delay = delay
    }

    func generate(_ context: CommandGeneratorContext) async throws -> String {
        contexts.append(context)
        if let delay { try await Task.sleep(for: delay) }
        return command
    }
}

@MainActor
private final class MobileSSHCommandConnectionBox {
    var draft = "list files"
    private(set) var writes: [Data] = []
    private(set) var shellIntegrationPreferences: [Bool] = []
    private var exits: [SSHSessionActor.ExitHandler] = []
    private var shellIntegrations: [SSHSessionActor.ShellIntegrationHandler] = []

    var sessionCount: Int { shellIntegrations.count }

    var services: MobileWorkspaceConnectionServices {
        MobileWorkspaceConnectionServices(
            makeSSHSession: { [weak self] output, exit, shellIntegration in
                self?.exits.append(exit)
                self?.shellIntegrations.append(shellIntegration)
                return SSHSessionActor(
                    output: output,
                    exit: exit,
                    shellIntegration: shellIntegration
                )
            },
            connectSSH: { [weak self] _, _, shellIntegrationEnabled, _, _, _ in
                self?.shellIntegrationPreferences.append(shellIntegrationEnabled)
            },
            connectSFTP: { _, _, _ in throw SFTPError.notConnected },
            writeSSH: { [weak self] _, data in
                guard let self else { return }
                writes.append(data)
                if data == Data("\u{1B}[777;1~".utf8) {
                    shellIntegrations.last?(.draft(draft))
                }
            }
        )
    }

    func sendShellEvents(
        _ events: [SSHShellIntegrationEvent],
        session index: Int? = nil
    ) async {
        let index = index ?? shellIntegrations.index(before: shellIntegrations.endIndex)
        let handler = shellIntegrations[index]
        await Task.detached {
            for event in events { handler(event) }
        }.value
    }

    func finishSession(
        _ result: Result<Int32, TermindSSHError>,
        session index: Int
    ) async {
        let handler = exits[index]
        await Task.detached { handler(result) }.value
    }
}

@Suite @MainActor
struct MobileCommandGeneratorTests {
    @Test func readsTheCurrentDraftAndInsertsWithoutExecuting() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        connections.draft = "show hidden files"
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        let systemInfo = RemoteSystemInfo(
            distributionID: "debian",
            distributionVersion: "13",
            kernelName: "Linux",
            kernelRelease: "6.12.0",
            architecture: "arm64"
        )
        workspace.receiveWorkingDirectory("/srv/app")
        await connections.sendShellEvents([
            .available(shell: "zsh", systemInfo: systemInfo, homeDirectory: "/home/test")
        ])
        #expect(await eventually { workspace.canGenerateFromCurrentDraft })
        let generator = MobileCommandGeneratorStub(command: "ls -la")

        workspace.generateCommand(using: generator)

        #expect(await eventually { workspace.commandGeneratorState == .inserted(targetCount: 1) })
        #expect(
            generator.contexts == [
                CommandGeneratorContext(
                    draft: "show hidden files",
                    shell: "zsh",
                    cwd: "/srv/app",
                    remoteSystemInfo: systemInfo
                )
            ]
        )
        #expect(connections.writes.first == Data("\u{1B}[777;1~".utf8))
        #expect(
            connections.writes.last
                == Data("\u{1B}[777;2~\u{1B}[200~ls -la\u{1B}[201~".utf8)
        )
        #expect(connections.writes.last?.contains(0x0A) == false)
        #expect(connections.writes.last?.contains(0x0D) == false)
    }

    @Test func unavailablePromptFailsWithoutReadingOrCallingTheModel() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        let generator = MobileCommandGeneratorStub(command: "ls")

        workspace.generateCommand(using: generator)

        guard case .failed = workspace.commandGeneratorState else {
            Issue.record("Expected an unavailable-prompt failure")
            return
        }
        #expect(generator.contexts.isEmpty)
        #expect(connections.writes.isEmpty)
    }

    @Test func sameDirectorySFTPLaunchRequiresLiveShellIntegrationAndWorkingDirectory() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }

        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/releases/")
        #expect(workspace.sameDirectoryLaunch == nil)

        await connections.sendShellEvents([
            .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test")
        ])

        #expect(
            await eventually {
                workspace.sameDirectoryLaunch
                    == MobileWorkspaceDirectoryLaunch(hostID: host.id, kind: .sftp, path: "/srv/releases")
            })
        workspace.receiveWorkingDirectory(nil)
        #expect(workspace.sameDirectoryLaunch == nil)
    }

    @Test func directoryStartupCommandRunsOnceWithoutEnteringHistory() async throws {
        let connections = MobileSSHCommandConnectionBox()
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        app.library.upsert(host)
        app.library.trust(
            KnownHostEntry(
                hostname: host.host,
                port: host.port,
                algorithm: .ed25519,
                fingerprint: "SHA256:test"
            ))
        let command = try #require(RemoteShellCommand.changeDirectory(to: "/srv/it's live"))
        let id = try #require(app.open(hostID: host.id, kind: .ssh, initialPath: "/srv/it's live"))
        let workspace = try #require(app.workspaces.first(where: { $0.id == id }))
        defer { app.close(id) }

        #expect(await eventually { workspace.connected })
        #expect(!connections.writes.contains(Data((command + "\r").utf8)))
        await connections.sendShellEvents([
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/test"),
            .commandStarted(command),
            .commandFinished(0, duration: 0.01),
            .commandStarted("pwd"),
            .commandFinished(0, duration: 0.02),
        ])

        #expect(await eventually { connections.writes.contains(Data((command + "\r").utf8)) })
        #expect(await eventually { app.commandHistory.entries(for: host.id).count == 1 })
        #expect(app.commandHistory.entries(for: host.id).first?.command == "pwd")
        #expect(workspace.pendingInitialCommand == nil)
    }

    @Test func snippetStartupCommandWritesOnceAfterSSHConnect() async throws {
        let connections = MobileSSHCommandConnectionBox()
        let app = try MobileAppModel(
            inMemory: true,
            workspaceConnectionServices: connections.services
        )
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        try app.library.upsert(identity, passwordUpdate: .replace("test-only"))
        app.library.upsert(host)
        app.library.trust(
            KnownHostEntry(
                hostname: host.host,
                port: host.port,
                algorithm: .ed25519,
                fingerprint: "SHA256:test"
            ))
        let snippet = Snippet(title: "Status", body: "uptime")
        let id = try #require(app.execute(snippet, on: [host.id]).first)
        let workspace = try #require(app.workspaces.first(where: { $0.id == id }))
        defer { app.close(id) }

        #expect(await eventually { workspace.connected })
        #expect(!connections.writes.contains(Data((snippet.body + "\r").utf8)))
        await connections.sendShellEvents([
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/test")
        ])
        #expect(await eventually { connections.writes.contains(Data((snippet.body + "\r").utf8)) })
        #expect(workspace.pendingInitialCommand == nil)
    }

    @Test func newTerminalInputCancelsAnInFlightGeneration() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/tmp")
        await connections.sendShellEvents([
            .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test"),
            .promptReady,
        ])
        #expect(await eventually { workspace.canGenerateFromCurrentDraft })
        let generator = MobileCommandGeneratorStub(command: "ls", delay: .seconds(30))
        workspace.generateCommand(using: generator)
        #expect(await eventually { workspace.commandGeneratorState == .generating })

        await workspace.receiveInteractiveTerminalInput(Data("new draft".utf8))

        #expect(await eventually { workspace.commandGeneratorState == .idle })
        #expect(!connections.writes.contains(Data("\u{1B}[777;2~\u{1B}[200~ls\u{1B}[201~".utf8)))
    }

    @Test func productionCallbacksStayOrderedAndIgnoreAnOldSession() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let history = CommandHistoryModel()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            commandHistory: history,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected && connections.sessionCount == 1 })
        workspace.receiveWorkingDirectory("/srv/app")

        await connections.sendShellEvents([
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/test"),
            .promptReady,
            .commandStarted("pwd"),
        ])

        #expect(await eventually { history.entries(for: host.id).count == 1 })
        #expect(!workspace.canGenerateFromCurrentDraft)

        await connections.sendShellEvents([
            .commandFinished(0, duration: 0.25)
        ])

        #expect(await eventually { workspace.canGenerateFromCurrentDraft })
        let entry = try #require(history.entries(for: host.id).first)
        #expect(entry.command == "pwd")
        #expect(entry.exitStatus == 0)
        #expect(entry.duration == 0.25)

        await connections.finishSession(.success(0), session: 0)
        #expect(await eventually { !workspace.connected })
        workspace.connect()
        #expect(await eventually { workspace.connected && connections.sessionCount == 2 })
        workspace.receiveWorkingDirectory("/srv/next")
        await connections.sendShellEvents([.commandStarted("stale")], session: 0)
        await connections.sendShellEvents(
            [
                .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test"),
                .promptReady,
            ], session: 1)

        #expect(await eventually { workspace.canGenerateFromCurrentDraft })
        #expect(!history.entries(for: host.id).contains { $0.command == "stale" })
    }

    @Test func disabledIntegrationIsPassedToTheTransportAndRemainsUnavailable() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let settings = TerminalSettingsModel()
        #expect(settings.set(false, for: \.shellIntegration))
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            terminalSettings: settings,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })

        await connections.sendShellEvents([
            .available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test"),
            .promptReady,
        ])

        #expect(await eventually { connections.shellIntegrationPreferences == [false] })
        #expect(!workspace.canGenerateFromCurrentDraft)
        workspace.receiveWorkingDirectory("/srv/app")
        #expect(workspace.sameDirectoryLaunch == nil)
    }

    @Test func unsupportedShellRemainsUnavailableAfterOrderedPromptEvents() async throws {
        let (host, library) = try commandFixture()
        let connections = MobileSSHCommandConnectionBox()
        let history = CommandHistoryModel()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            commandHistory: history,
            connectionServices: connections.services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/app")

        await connections.sendShellEvents([
            .available(shell: "tcsh", systemInfo: nil, homeDirectory: "/home/test"),
            .promptReady,
            .commandStarted("echo marker"),
            .promptReady,
        ])

        #expect(await eventually { history.entries(for: host.id).count == 1 })
        #expect(!workspace.canGenerateFromCurrentDraft)
        let generator = MobileCommandGeneratorStub(command: "echo generated")
        workspace.generateCommand(using: generator)
        guard case .failed = workspace.commandGeneratorState else {
            Issue.record("Expected an unsupported-shell failure")
            return
        }
        #expect(generator.contexts.isEmpty)
        #expect(connections.writes.isEmpty)
    }

    private func commandFixture() throws -> (Host, HostLibraryModel) {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host],
            identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host,
                    port: host.port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            ]
        )
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        return (host, library)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@Suite @MainActor
struct MobileUploadBatchTests {
    @Test func usernameOnlyTerminalUploadRejectsInteractionWithoutOpeningASheet() async throws {
        let identity = Identity(name: "OTP", username: "user")
        let host = Host(name: "OTP", host: "example.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        let client = MobileUploadSFTPClient()
        let transfers = SFTPTransferCoordinator(store: library) { client }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { request, _, _ in
                #expect(request.interactionPolicy == .forbidden)
                #expect(request.configuration.credentials.isEmpty)
                let handler = try #require(request.enforcingInteractionPolicy().keyboardInteractive)
                _ = try await handler(
                    SSHKeyboardInteractiveChallenge(
                        connectionID: UUID(), hostID: host.id, hostname: host.host, port: 22,
                        username: "user", round: 1, name: "OTP", instruction: "",
                        prompts: [.init(text: "Code", echo: false)]))
                return client
            }, writeSSH: { _, _ in }
        )
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library, transfers: transfers, connectionServices: services)
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/current")
        #expect(workspace.uploadTargetProblem == nil)
        #expect(workspace.prepareUpload([URL(fileURLWithPath: "/tmp/termind-test-upload")]))
        #expect(await eventually { workspace.uploadNotice?.isRejected == true })
        #expect(workspace.operationError == nil)
        #expect(workspace.keyboardAuthentication.current == nil)
        #expect(transfers.sftpTransfers.isEmpty)
    }

    @Test(arguments: [UploadFailureStage.connection, .localFile, .preparation, .enqueue])
    private func terminalUploadFailuresUseNoticesAndReleaseTheClient(_ stage: UploadFailureStage) async throws {
        let client = MobileUploadSFTPClient(failureStage: stage)
        let workspace = uploadWorkspace(client: client) {
            if stage == .connection { throw URLError(.cannotConnectToHost) }
            return client
        }
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/current")
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: source) }
        if stage == .enqueue {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        } else if stage != .localFile {
            try Data("upload".utf8).write(to: source)
        }

        #expect(workspace.prepareUpload([source]))
        #expect(await eventually { workspace.uploadNotice?.isRejected == true })
        #expect(workspace.operationError == nil)
        #expect(workspace.transfers?.sftpTransfers.isEmpty == true)
        #expect(!workspace.hasPendingTransferConflict)
        if stage != .connection { #expect(await client.disconnectCount == 1) }
    }

    @Test func browserUploadFailuresKeepTheirOperationAlert() async throws {
        let client = MobileUploadSFTPClient()
        let workspace = uploadWorkspace(client: client, kind: .sftp)
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        let missing = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        #expect(workspace.prepareUpload([missing]))
        #expect(await eventually { workspace.operationError != nil })
        #expect(workspace.uploadNotice == nil)
        #expect(await client.disconnectCount == 0)
        workspace.reportUploadFailure("Provider failed")
        #expect(workspace.operationError == "Provider failed")
        #expect(workspace.uploadNotice == nil)
    }

    @Test func partialFileProviderFailureStaysVisibleWhileReadableFilesAreQueued() async throws {
        let client = MobileUploadSFTPClient()
        let workspace = uploadWorkspace(client: client)
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/current")
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("readable".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let good = NSItemProvider()
        good.suggestedName = "good.txt"
        good.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all
        ) { completion in
            completion(source, false, nil)
            return nil
        }
        let bad = NSItemProvider()
        bad.suggestedName = "bad.txt"
        bad.registerFileRepresentation(
            forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all
        ) { completion in
            completion(nil, false, CocoaError(.fileReadNoPermission))
            return nil
        }
        let payload = await MobileDropPayloadLoader.load([good, bad], kinds: [.files], fileMode: .staged)
        defer {
            if let root = payload.stagedRoot { try? FileManager.default.removeItem(at: root) }
        }
        let error = try #require(payload.failures.first)
        #expect(workspace.prepareUpload(payload.fileURLs))
        workspace.reportUploadFailure(error)
        #expect(await eventuallyAsync { await client.disconnectCount == 1 })
        #expect(workspace.transfers?.sftpTransfers.count == 1)
        #expect(workspace.uploadNotice == .rejected(error))
        #expect(workspace.operationError == nil)

        // A new batch replaces the partial-failure notice and restores the ordinary success timer.
        #expect(workspace.prepareUpload([source]))
        #expect(workspace.uploadNotice == .preparing("/srv/current"))
        #expect(await eventually { workspace.uploadNotice == .queued(1, "/srv/current") })
        try await Task.sleep(for: .milliseconds(2300))
        #expect(workspace.uploadNotice == nil)
    }

    @Test func repeatedFailuresRestartTheThreeSecondDismissalTimer() async throws {
        let workspace = uploadWorkspace(client: MobileUploadSFTPClient())
        defer { workspace.disconnect() }
        workspace.reportUploadFailure("Unreadable file")
        try await Task.sleep(for: .milliseconds(1600))
        workspace.reportUploadFailure("Unreadable file")
        try await Task.sleep(for: .milliseconds(1600))
        #expect(workspace.uploadNotice == .rejected("Unreadable file"))
        try await Task.sleep(for: .milliseconds(1700))
        #expect(workspace.uploadNotice == nil)
        #expect(workspace.operationError == nil)
    }

    @Test(arguments: [false, true])
    func cancelledOpeningCannotReplaceANewerDropFailure(_ lateFailure: Bool) async throws {
        let client = MobileUploadSFTPClient()
        let opening = MobileUploadOpeningGate()
        let workspace = uploadWorkspace(client: client) {
            if opening.hasStarted { throw URLError(.timedOut) }
            return try await opening.open()
        }
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/current")
        let source = URL(fileURLWithPath: "/tmp/unused-upload")
        #expect(workspace.prepareUpload([source]))
        #expect(await eventually { opening.hasStarted })
        workspace.cancelPendingUpload()
        #expect(workspace.uploadNotice == nil)
        #expect(workspace.operationError == nil)
        #expect(workspace.prepareUpload([source]))
        #expect(await eventually { workspace.uploadNotice?.isRejected == true })
        let notice = workspace.uploadNotice
        opening.finish(lateFailure ? .failure(SSHInteractionRequired()) : .success(client))
        #expect(await eventually { opening.hasFinished })
        if !lateFailure { #expect(await eventuallyAsync { await client.disconnectCount == 1 }) }
        #expect(workspace.uploadNotice == notice)
        #expect(workspace.operationError == nil)
        #expect(workspace.transfers?.sftpTransfers.isEmpty == true)
        workspace.cancelPendingUpload()
        #expect(workspace.uploadNotice == nil)
    }

    private func uploadWorkspace(
        client: MobileUploadSFTPClient,
        kind: ConnectionHistoryEntry.Kind = .ssh,
        open: (() async throws -> any SFTPClientProtocol)? = nil
    ) -> MobileWorkspace {
        let identity = Identity(name: "Upload", username: "user")
        let host = Host(name: "Upload", host: "example.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        let transfers = SFTPTransferCoordinator(store: library) { client }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in
                if let open { return try await open() }
                return client
            }, writeSSH: { _, _ in })
        return MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: kind),
            hosts: library, transfers: transfers, connectionServices: services)
    }

    @Test func serialUploadSurvivesClosingTheSFTPWorkspace() async throws {
        let identity = Identity(name: "OTP", username: "user")
        let host = Host(name: "OTP", host: "example.invalid", identityID: identity.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity])
        let primary = MobileUploadSFTPClient(blocksUpload: true)
        let extra = MobileUploadSFTPClient(requiresInteraction: true)
        let transfers = SFTPTransferCoordinator(store: library) { extra }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in }, connectSFTP: { _, _, _ in primary }, writeSSH: { _, _ in })
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library, transfers: transfers, connectionServices: services)
        workspace.connect()
        #expect(await eventually { workspace.connected })
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(workspace.prepareUpload([file]))
        #expect(await eventuallyAsync { await primary.startedUploads == 1 })
        workspace.disconnect()
        #expect(await primary.disconnectCount == 0)
        await primary.finishUploads()
        #expect(await eventually { transfers.sftpTransfers.allSatisfy { $0.state == .completed } })
        #expect(await eventuallyAsync { await primary.disconnectCount == 1 })
    }

    @Test func sshUploadUsesTheReportedWorkingDirectoryAndReleasesPreflightClient() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host],
            identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host,
                    port: host.port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            ]
        )
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let preflightClient = MobileUploadSFTPClient()
        let transferClient = MobileUploadSFTPClient()
        let transfers = SFTPTransferCoordinator(store: library) { transferClient }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { request, _, _ in
                #expect(request.interactionPolicy == .forbidden)
                return preflightClient
            },
            writeSSH: { _, _ in }
        )
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .ssh),
            hosts: library,
            transfers: transfers,
            connectionServices: services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        workspace.receiveWorkingDirectory("/srv/current")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "report.txt")
        try Data("report".utf8).write(to: file)

        #expect(workspace.prepareUpload([file]))

        #expect(await eventually { transfers.sftpTransfers.count == 1 })
        #expect(transfers.sftpTransfers.first?.remotePath == "/srv/current/report.txt")
        #expect(await eventuallyAsync { await preflightClient.disconnectCount == 1 })
    }

    @Test func sftpFolderUploadUsesTheCurrentDirectoryAndOneBatch() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host],
            identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host,
                    port: host.port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            ]
        )
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let client = MobileUploadSFTPClient()
        let transfers = SFTPTransferCoordinator(store: library) { client }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in client },
            writeSSH: { _, _ in }
        )
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            transfers: transfers,
            connectionServices: services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })
        await workspace.sftpSession.openDirectory("/srv/incoming")
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "bundle", directoryHint: .isDirectory)
        let nested = folder.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("payload".utf8).write(to: nested.appending(path: "payload.txt"))
        let looseFile = root.appending(path: "README.md")
        try Data("readme".utf8).write(to: looseFile)

        let providers = [(folder, UTType.folder), (looseFile, UTType.plainText)].map { url, type in
            let provider = NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) {
                @Sendable completion in
                completion(url, false, nil)
                return nil
            }
            return provider
        }
        let payload = await MobileDropPayloadLoader.load(providers, kinds: [.files], fileMode: .staged)
        defer { if let root = payload.stagedRoot { try? FileManager.default.removeItem(at: root) } }
        #expect(payload.failures.isEmpty)
        try FileManager.default.removeItem(at: root)
        #expect(workspace.prepareUpload(payload.fileURLs))

        #expect(await eventually { transfers.sftpTransfers.count == 2 })
        #expect(
            Set(transfers.sftpTransfers.map(\.remotePath)) == [
                "/srv/incoming/README.md",
                "/srv/incoming/bundle/nested/payload.txt",
            ]
        )
        #expect(Set(transfers.sftpTransfers.map(\.batchID)).count == 1)
        #expect(await eventuallyAsync { await client.uploadedData.count == 2 })
        #expect(
            await client.uploadedData == [
                "/srv/incoming/README.md": Data("readme".utf8),
                "/srv/incoming/bundle/nested/payload.txt": Data("payload".utf8),
            ])
        #expect(workspace.uploadNotice == .queued(2, "/srv/incoming"))
        #expect(
            await client.createdDirectories == [
                "/srv/incoming/bundle",
                "/srv/incoming/bundle/nested",
            ]
        )
    }

    @Test func successfulFileDownloadsRefreshHistoryWhileInvalidAndFailedFilesDoNot() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = Host(name: "Example", host: "example.invalid")
        host.identityID = identity.id
        let library = HostLibraryModel(
            hosts: [host],
            identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host,
                    port: host.port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            ]
        )
        try library.upsert(identity, passwordUpdate: .replace("test-only"))
        let report = RemoteFile(
            path: "/srv/report.txt", name: "report.txt", kind: .file, size: 4,
            permissions: 0o644, ownerUID: 501, ownerGID: 20)
        let broken = RemoteFile(
            path: "/srv/broken.txt", name: "broken.txt", kind: .file, size: 4,
            permissions: 0o644, ownerUID: 501, ownerGID: 20)
        let changedDirectory = RemoteFile(
            path: "/srv/changed", name: "changed", kind: .directory, size: 0,
            permissions: 0o755, ownerUID: 501, ownerGID: 20)
        let sessionClient = MobileUploadSFTPClient(
            attributes: [
                report.path: report,
                broken.path: broken,
                changedDirectory.path: changedDirectory,
            ])
        let transferClient = MobileUploadSFTPClient(failedDownloadPaths: [broken.path])
        let transfers = SFTPTransferCoordinator(store: library) { transferClient }
        let services = MobileWorkspaceConnectionServices(
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in sessionClient },
            writeSSH: { _, _ in }
        )
        let history = SFTPHistoryModel()
        let workspace = MobileWorkspace(
            descriptor: MobileWorkspaceDescriptor(hostID: host.id, title: host.name, kind: .sftp),
            hosts: library,
            transfers: transfers,
            sftpHistory: history,
            connectionServices: services
        )
        defer { workspace.disconnect() }
        workspace.connect()
        #expect(await eventually { workspace.connected })

        #expect(await workspace.reopenHistoryFile(at: report.path))
        #expect(
            await eventually {
                history.entries(for: host.id).contains { $0.kind == .file && $0.path == report.path }
            })

        #expect(await workspace.reopenHistoryFile(at: broken.path))
        #expect(
            await eventually {
                guard let state = transfers.sftpTransfers.first(where: { $0.remotePath == broken.path })?.state
                else { return false }
                if case .failed = state { return true }
                return false
            })
        #expect(!history.entries(for: host.id).contains { $0.path == broken.path })

        #expect(!(await workspace.reopenHistoryFile(at: "/srv/missing.txt")))
        #expect(!(await workspace.reopenHistoryFile(at: changedDirectory.path)))
        #expect(!history.entries(for: host.id).contains { $0.path == changedDirectory.path })
    }

    @Test func sharedUploadPlannerDoesNotFollowASymlinkOutsideTheSelectedFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let upload = root.appending(path: "upload", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: upload, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("inside".utf8).write(to: upload.appending(path: "inside.txt"))
        let outside = root.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: upload.appending(path: "escape.txt"),
            withDestinationURL: outside
        )
        let client = MobileUploadSFTPClient()

        let batch = try await SFTPLocalUploadPlanner.prepare(
            [upload],
            destination: "/incoming",
            client: client
        )

        #expect(batch.transferCount == 1)
        #expect(batch.rootCount == 1)
    }

    @Test func sharedUploadPlannerCreatesAnEmptyFolderWithoutInventingATransfer() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let emptyFolder = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MobileUploadSFTPClient()
        let hostID = UUID()
        let configuration = SSHConnectionConfiguration(
            hostID: hostID,
            host: "example.invalid",
            port: 22,
            username: "deploy",
            credentials: [],
            expectedHostKeys: []
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
        let batch = try await SFTPLocalUploadPlanner.prepare(
            [emptyFolder],
            destination: "/incoming",
            client: client
        )

        let result = try await SFTPLocalUploadPlanner.enqueue(
            batch,
            policy: .replace,
            hostID: hostID,
            connection: .saved(configuration),
            client: client,
            coordinator: coordinator
        )

        #expect(batch.transferCount == 0)
        #expect(!batch.isEmpty)
        #expect(result.transferCount == 0)
        #expect(result.changedRemoteDirectories)
        #expect(await client.createdDirectories == ["/incoming/empty"])
        #expect(coordinator.sftpTransfers.isEmpty)
    }

    @Test func sharedUploadReplaceRejectsAChildOutsideTheConflictingDirectory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appending(path: "payload.txt")
        try Data("replacement".utf8).write(to: local)
        let target = RemoteFile(
            path: "/incoming/payload.txt", name: "payload.txt", kind: .directory, size: 0,
            permissions: 0o755, ownerUID: 501, ownerGID: 20)
        let escaped = RemoteFile(
            path: "/outside/untouched.txt", name: "untouched.txt", kind: .file, size: 1,
            permissions: 0o644, ownerUID: 501, ownerGID: 20)
        let client = MobileUploadSFTPClient(attributes: [target.path: target], children: [target.path: [escaped]])
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
        let hostID = UUID()
        let configuration = SSHConnectionConfiguration(
            hostID: hostID, host: "example.invalid", port: 22, username: "deploy",
            credentials: [], expectedHostKeys: [])
        let batch = try await SFTPLocalUploadPlanner.prepare([local], destination: "/incoming", client: client)
        #expect(batch.conflictCount == 1)

        await #expect(throws: (any Error).self) {
            try await SFTPLocalUploadPlanner.enqueue(
                batch, policy: .replace, hostID: hostID, connection: .saved(configuration),
                client: client, coordinator: coordinator)
        }
        #expect(await client.listedDirectories == [target.path])
        #expect(await client.removedPaths.isEmpty)
        #expect(coordinator.sftpTransfers.isEmpty)
    }

    @Test func cancelledUploadDoesNotCreateRemoteDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let client = MobileUploadSFTPClient()
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
        let hostID = UUID()
        let configuration = SSHConnectionConfiguration(
            hostID: hostID, host: "example.invalid", port: 22, username: "deploy",
            credentials: [], expectedHostKeys: [])
        let batch = try await SFTPLocalUploadPlanner.prepare([folder], destination: "/incoming", client: client)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SFTPLocalUploadPlanner.enqueue(
                batch, policy: .replace, hostID: hostID, connection: .saved(configuration),
                client: client, coordinator: coordinator)
        }

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await client.createdDirectories.isEmpty)
        #expect(coordinator.sftpTransfers.isEmpty)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func eventuallyAsync(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<100 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private nonisolated enum UploadFailureStage: Sendable {
    case connection, localFile, preparation, enqueue
}

@MainActor
private final class MobileUploadOpeningGate {
    private var continuation: CheckedContinuation<any SFTPClientProtocol, any Error>?
    private(set) var hasStarted = false
    private(set) var hasFinished = false

    func open() async throws -> any SFTPClientProtocol {
        defer { hasFinished = true }
        return try await withCheckedThrowingContinuation {
            continuation = $0
            hasStarted = true
        }
    }

    func finish(_ result: Result<any SFTPClientProtocol, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

private actor MobileUploadSFTPClient: SFTPClientProtocol {
    private(set) var uploadedData: [String: Data] = [:]
    private(set) var createdDirectories: [String] = []
    private(set) var listedDirectories: [String] = []
    private(set) var removedPaths: [String] = []
    private(set) var disconnectCount = 0
    private(set) var startedUploads = 0
    private let blocksUpload: Bool
    private let requiresInteraction: Bool
    private let failureStage: UploadFailureStage?
    private var uploadWaiters: [CheckedContinuation<Void, Never>] = []
    private let attributes: [String: RemoteFile]
    private let failedDownloadPaths: Set<String>
    private let children: [String: [RemoteFile]]

    init(
        attributes: [String: RemoteFile] = [:],
        failedDownloadPaths: Set<String> = [],
        children: [String: [RemoteFile]] = [:],
        blocksUpload: Bool = false, requiresInteraction: Bool = false,
        failureStage: UploadFailureStage? = nil
    ) {
        self.blocksUpload = blocksUpload
        self.requiresInteraction = requiresInteraction
        self.failureStage = failureStage
        self.attributes = attributes
        self.failedDownloadPaths = failedDownloadPaths
        self.children = children
    }

    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {
        if requiresInteraction { throw SSHInteractionRequired() }
    }
    func finishUploads() {
        let pending = uploadWaiters
        uploadWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
    func disconnect() async { disconnectCount += 1 }
    func homeDirectory() async throws -> String { "/home/test" }
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        listedDirectories.append(path)
        return children[path, default: []]
    }
    func attributes(at path: String) async throws -> RemoteFile? {
        if failureStage == .preparation { throw SFTPError.operation("Cannot inspect upload destination") }
        return attributes[path]
    }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {
        if failureStage == .enqueue { throw SFTPError.operation("Cannot create upload directory") }
        createdDirectories.append(path)
    }
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws { removedPaths.append(path) }
    func removeDirectory(at path: String) async throws { removedPaths.append(path) }
    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        startedUploads += 1
        if blocksUpload { await withCheckedContinuation { uploadWaiters.append($0) } }
        uploadedData[remotePath] = try Data(contentsOf: localURL)
    }
    func downloadFile(
        from remotePath: String,
        to localURL: URL,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        if failedDownloadPaths.contains(remotePath) {
            throw SFTPError.operation("Download failed")
        }
    }
}

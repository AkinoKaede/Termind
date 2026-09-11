import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

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
    private var shellIntegration: SSHSessionActor.ShellIntegrationHandler?

    var services: MobileWorkspaceConnectionServices {
        MobileWorkspaceConnectionServices(
            discoverHostKey: { _, host, port, _, _ in
                SSHHostKeyObservation(
                    hostname: host,
                    port: port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            },
            makeSSHSession: { [weak self] output, exit, shellIntegration in
                self?.shellIntegration = shellIntegration
                return SSHSessionActor(
                    output: output,
                    exit: exit,
                    shellIntegration: shellIntegration
                )
            },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in throw SFTPError.notConnected },
            writeSSH: { [weak self] _, data in
                guard let self else { return }
                writes.append(data)
                if data == Data("\u{1B}[777;1~".utf8) {
                    shellIntegration?(.draft(draft))
                }
            }
        )
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
        workspace.receiveShellEvent(.available(shell: "zsh", systemInfo: systemInfo, homeDirectory: "/home/test"))
        workspace.receiveShellEvent(.promptReady)
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
        workspace.receiveShellEvent(.available(shell: "bash", systemInfo: nil, homeDirectory: "/home/test"))
        workspace.receiveShellEvent(.promptReady)
        let generator = MobileCommandGeneratorStub(command: "ls", delay: .seconds(30))
        workspace.generateCommand(using: generator)
        #expect(await eventually { workspace.commandGeneratorState == .generating })

        await workspace.receiveInteractiveTerminalInput(Data("new draft".utf8))

        #expect(await eventually { workspace.commandGeneratorState == .idle })
        #expect(!connections.writes.contains(Data("\u{1B}[777;2~\u{1B}[200~ls\u{1B}[201~".utf8)))
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
            discoverHostKey: { _, name, port, _, _ in
                SSHHostKeyObservation(
                    hostname: name,
                    port: port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            },
            makeSSHSession: { SSHSessionActor(output: $0, exit: $1, shellIntegration: $2) },
            connectSSH: { _, _, _, _, _, _ in },
            connectSFTP: { _, _, _ in preflightClient },
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
            discoverHostKey: { _, name, port, _, _ in
                SSHHostKeyObservation(
                    hostname: name,
                    port: port,
                    algorithm: .ed25519,
                    fingerprint: "SHA256:test"
                )
            },
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
        await workspace.openDirectory("/srv/incoming")
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let folder = root.appending(path: "bundle", directoryHint: .isDirectory)
        let nested = folder.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("payload".utf8).write(to: nested.appending(path: "payload.txt"))
        let looseFile = root.appending(path: "README.md")
        try Data("readme".utf8).write(to: looseFile)

        #expect(workspace.prepareUpload([folder, looseFile]))

        #expect(await eventually { transfers.sftpTransfers.count == 2 })
        #expect(
            Set(transfers.sftpTransfers.map(\.remotePath)) == [
                "/srv/incoming/README.md",
                "/srv/incoming/bundle/nested/payload.txt",
            ]
        )
        #expect(Set(transfers.sftpTransfers.map(\.batchID)).count == 1)
        #expect(workspace.uploadNotice == .queued(2, "/srv/incoming"))
        #expect(
            await client.createdDirectories == [
                "/srv/incoming/bundle",
                "/srv/incoming/bundle/nested",
            ]
        )
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

private actor MobileUploadSFTPClient: SFTPClientProtocol {
    private(set) var createdDirectories: [String] = []
    private(set) var disconnectCount = 0

    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func disconnect() async { disconnectCount += 1 }
    func homeDirectory() async throws -> String { "/home/test" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws { createdDirectories.append(path) }
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL,
        to remotePath: String,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
    func downloadFile(
        from remotePath: String,
        to localURL: URL,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {}
}

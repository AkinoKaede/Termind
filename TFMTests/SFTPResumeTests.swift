import CryptoKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
@MainActor
struct SFTPResumeTests {
    @Test(arguments: [SFTPTransfer.Direction.upload, .download])
    func pauseReleasesConnectionAndResumeRetainsProgressAndCompletion(_ direction: SFTPTransfer.Direction) async throws
    {
        let client = ResumeQueueClient()
        let store = HostLibraryModel()
        let coordinator = SFTPTransferCoordinator(store: store, clientFactory: { client })
        let hostID = UUID()
        let root = FileManager.default.temporaryDirectory
        var completions: [SFTPTransfer.State] = []
        coordinator.enqueue(
            direction: direction, batchID: UUID(), localURL: root.appendingPathComponent(UUID().uuidString),
            remotePath: "/file", byteCount: 4, hostID: hostID,
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "test", port: 22, username: "test", credentials: [], expectedHostKeys: []),
            scopedRoot: root, overwrite: true, completion: { completions.append($0) }
        )
        let id = try #require(coordinator.sftpTransfers.first?.id)
        try await waitUntil { await client.checkpoint?.snapshot.offset == 2 }
        coordinator.pause(id)
        try await waitUntil { coordinator.sftpTransfers.first?.state == .paused }
        #expect(coordinator.activeCount == 0)
        #expect(coordinator.sftpTransfers.first?.transferredBytes == 2)
        #expect(await client.disconnects == 1)
        #expect(completions.isEmpty)
        coordinator.resume(id)
        try await waitUntil { coordinator.sftpTransfers.first?.state == .completed }
        #expect(await client.offsets == [0, 2])
        #expect(await client.disconnects == 2)
        #expect(completions == [.completed])
        #expect(coordinator.sftpTransfers.first?.transferredBytes == 4)
    }

    @Test
    func connectionLossPausesAndCancellingPausedTransferFinishesOnlyOnce() async throws {
        let client = ResumeQueueClient(connectionLoss: true)
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel(), clientFactory: { client })
        var completions: [SFTPTransfer.State] = []
        let root = FileManager.default.temporaryDirectory
        coordinator.enqueue(
            direction: .upload, batchID: UUID(), localURL: root.appendingPathComponent(UUID().uuidString),
            remotePath: "/file", byteCount: 4, hostID: UUID(),
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "test", port: 22, username: "test", credentials: [], expectedHostKeys: []),
            scopedRoot: root, overwrite: true, completion: { completions.append($0) }
        )
        let id = try #require(coordinator.sftpTransfers.first?.id)
        try await waitUntil { coordinator.sftpTransfers.first?.state == .paused }
        #expect(completions.isEmpty)
        coordinator.cancelAll()
        await coordinator.waitForCancellation()
        #expect(coordinator.sftpTransfers.first?.state == .cancelled)
        #expect(completions == [.cancelled])
        coordinator.resume(id)
        #expect(coordinator.activeCount == 0)
    }

    @Test func cancellingAPausedUploadDoesNotOpenAnotherAuthenticationPromptForCleanup() async throws {
        let queue = SSHKeyboardInteractiveQueue()
        let client = ResumeQueueClient(cleanupAuthentication: queue.handler)
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel(), clientFactory: { client })
        defer { queue.cancelAll() }
        let root = FileManager.default.temporaryDirectory
        coordinator.enqueue(
            direction: .upload, batchID: UUID(), localURL: root.appendingPathComponent(UUID().uuidString),
            remotePath: "/file", byteCount: 4, hostID: UUID(),
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "test", port: 22, username: "test", credentials: [], expectedHostKeys: []),
            scopedRoot: root, overwrite: true)
        let id = try #require(coordinator.sftpTransfers.first?.id)
        try await waitUntil { await client.checkpoint?.snapshot.offset == 2 }
        coordinator.pause(id)
        try await waitUntil { coordinator.sftpTransfers.first?.state == .paused }
        coordinator.cancel(id)
        try await waitUntil { coordinator.sftpTransfers.first?.state != .paused }
        #expect(queue.current == nil)
        // A remote temporary file requiring new MFA cannot be silently deleted.
        guard case .failed? = coordinator.sftpTransfers.first?.state else {
            Issue.record("Expected the existing temporary-file cleanup failure report")
            return
        }
        #expect(await client.connections == 2)
    }

    @Test
    func checkpointRejectsChangedSourceAndHashesOnlyAcknowledgedBytes() throws {
        let state = SFTPResumeState()
        let identity = SFTPSourceIdentity(byteCount: 4, modifiedAt: Date(timeIntervalSince1970: 1))
        try state.validateSource(identity)
        state.acknowledge(Data([1, 2]))
        let before = state.snapshot
        state.acknowledge(Data([3, 4]))
        #expect(before.offset == 2)
        #expect(before.digest.finalize() == SHA256.hash(data: Data([1, 2])))
        #expect(state.snapshot.digest.finalize() == SHA256.hash(data: Data([1, 2, 3, 4])))
        #expect(throws: SFTPResumeFailure.self) {
            try state.validateSource(SFTPSourceIdentity(byteCount: 4, modifiedAt: Date(timeIntervalSince1970: 2)))
        }
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Transfer did not reach the expected state")
        throw SFTPError.notConnected
    }
}

private actor ResumeQueueClient: SFTPClientProtocol {
    var checkpoint: SFTPResumeState?
    var offsets: [Int64] = []
    var disconnects = 0
    let connectionLoss: Bool
    let cleanupAuthentication: SSHKeyboardInteractiveHandler?
    var connections = 0
    init(connectionLoss: Bool = false, cleanupAuthentication: SSHKeyboardInteractiveHandler? = nil) {
        self.connectionLoss = connectionLoss
        self.cleanupAuthentication = cleanupAuthentication
    }
    func run(
        _ state: SFTPResumeState, token: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        checkpoint = state
        if cleanupAuthentication != nil { _ = state.temporaryPath(for: "/file") }
        let offset = state.snapshot.offset
        offsets.append(offset)
        try state.validateSource(SFTPSourceIdentity(byteCount: 4, modifiedAt: nil))
        state.acknowledge(offset == 0 ? Data([1, 2]) : Data([3, 4]))
        progress(SFTPProgress(completedBytes: state.snapshot.offset, totalBytes: 4, bytesPerSecond: 0))
        if offset == 0 {
            if connectionLoss { throw SFTPError.connectionLost("lost") }
            await withCheckedContinuation { continuation in
                _ = token.observeCancellation { continuation.resume() }
            }
            throw SFTPError.cancelled
        }
    }
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await run(resume, token: cancellation, progress: progress)
    }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await run(resume, token: cancellation, progress: progress)
    }
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw SFTPResumeFailure.unsupported }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { throw SFTPResumeFailure.unsupported }
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}
    func connect(
        using request: SSHConnectionRequest, progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        connections += 1
        guard connections > 1, let handler = request.keyboardInteractive ?? cleanupAuthentication else { return }
        let configuration = request.configuration
        _ = try await handler(
            SSHKeyboardInteractiveChallenge(
                connectionID: UUID(), hostID: configuration.hostID, hostname: configuration.host,
                port: configuration.port,
                username: configuration.username, round: 1, name: "OTP", instruction: "",
                prompts: [.init(text: "Code", echo: false)]))
    }
    func disconnect() async { disconnects += 1 }
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
}

import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct SFTPTransferSessionTests {
    @Test func terminalUploadKeepsASuccessfulIndependentConnection() async throws {
        let resolution = UploadConnectionResolutionHarness(independent: .success)
        let result = try await TerminalUploadConnectionResolver.resolve(
            isCurrent: { true },
            connectIndependent: { try await resolution.connectIndependent() },
            openTerminalChannel: { await resolution.openTerminalChannel() })
        #expect(result.primaryRole == .donatedConnection)
        #expect(await resolution.fallbacks == 0)
    }

    @Test func terminalUploadFallsBackWhenTheIndependentConnectionNeedsInteraction() async throws {
        let resolution = UploadConnectionResolutionHarness(independent: .interactionRequired)
        let result = try await TerminalUploadConnectionResolver.resolve(
            isCurrent: { true },
            connectIndependent: { try await resolution.connectIndependent() },
            openTerminalChannel: { await resolution.openTerminalChannel() })
        #expect(result.primaryRole == .terminalFallback)
        #expect(await resolution.fallbacks == 1)
    }

    @Test func terminalUploadDoesNotFallBackAfterCancellationOrRetirement() async throws {
        let cancelled = UploadConnectionResolutionHarness(independent: .cancelled)
        await #expect(throws: CancellationError.self) {
            try await TerminalUploadConnectionResolver.resolve(
                isCurrent: { true },
                connectIndependent: { try await cancelled.connectIndependent() },
                openTerminalChannel: { await cancelled.openTerminalChannel() })
        }
        #expect(await cancelled.fallbacks == 0)

        let retired = UploadConnectionResolutionHarness(independent: .interactionRequired)
        await #expect(throws: CancellationError.self) {
            try await TerminalUploadConnectionResolver.resolve(
                isCurrent: { false },
                connectIndependent: { try await retired.connectIndependent() },
                openTerminalChannel: { await retired.openTerminalChannel() })
        }
        #expect(await retired.fallbacks == 0)
    }

    @Test func closingTheDesktopPaneKeepsItsSerialUploadAlive() async throws {
        let harness = TransferSessionHarness(behaviors: [.interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "fixture", port: 22, username: "user", credentials: [], expectedHostKeys: [])
        let store = HostLibraryModel()
        let coordinator = SFTPTransferCoordinator(
            store: store, clientFactory: { TransferSessionClient(harness: harness) },
            strategy: .connectionsPreferred)
        let browser = SFTPSessionModel(
            hostID: configuration.hostID, initialPath: "/", client: primary, configuration: configuration)
        browser.bindStatus(to: store)
        #expect(store.status(of: configuration.hostID) == .connected)
        let workspace = Workspace(pane: Pane(.sftpSession(browser)))
        let window = WindowModel(workspaces: [workspace])
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await browser.prepareUpload([file])
        await browser.enqueuePending(policy: .replace, coordinator: coordinator)
        try await eventually { await harness.started == 1 }

        window.closePane(workspace.focusedPane.id)
        #expect(window.workspaces.isEmpty)
        #expect(store.status(of: configuration.hostID) == .connected)
        #expect(await primary.disconnects == 0)
        await harness.releaseOne()
        try await eventually { coordinator.activeCount == 0 }
        #expect(coordinator.sftpTransfers.first?.state == .completed)
        #expect(store.status(of: configuration.hostID) == .disconnected)
        #expect(await primary.disconnects == 1)
    }

    @Test func cancellingDetachedChannelTransfersReleasesTheLastConnection() async throws {
        let harness = TransferSessionHarness(behaviors: [.interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness)
        enqueue(3, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 3 }
        await session.releaseOwner()
        coordinator.cancelAll()
        await coordinator.waitForCancellation()
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .cancelled })
        #expect(await primary.disconnects == 1)
        #expect(await harness.started == 3)
    }

    @Test func serialRemoteCopySharesOneLeaseForBothEndpoints() async throws {
        let harness = TransferSessionHarness(behaviors: [.interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness)
        coordinator.enqueueRemoteCopy(
            batchID: UUID(), sourcePath: "/source", sourceHostID: session.configuration.hostID,
            sourceConnection: .session(session), destinationPath: "/copy",
            destinationHostID: session.configuration.hostID, destinationConnection: .session(session),
            byteCount: 1, overwrite: false)
        try await eventually { await harness.started == 1 }
        await session.releaseOwner()
        #expect(await primary.disconnects == 0)
        #expect(await harness.opens == 1)
        await harness.releaseOne()
        try await eventually { coordinator.activeCount == 0 }
        #expect(coordinator.sftpTransfers.first?.state == .completed)
        #expect(await primary.disconnects == 1)
    }

    @Test func failedSilentProbeFallsBackToBoundedSiblingChannels() async throws {
        let harness = TransferSessionHarness(behaviors: [.interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness)
        enqueue(3, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 3 }
        await session.releaseOwner()
        #expect(await primary.disconnects == 0)
        #expect(await harness.opens == 1)
        #expect(await harness.policies == [.forbidden])
        #expect(await harness.siblingChannels == 3)
        #expect(coordinator.activeCount == 3)
        #expect(await harness.maximumActive == 3)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        #expect(await primary.disconnects == 1)
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .completed })
        #expect(await harness.opens == 1)
    }

    @Test func channelsOnlyUsesSiblingChannelsWithoutOpeningConnections() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, limit: 3, strategy: .channelsOnly)
        enqueue(3, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 3 }
        #expect(await harness.opens == 0)
        #expect(await harness.siblingChannels == 3)
        #expect(await harness.maximumActive == 3)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        await session.releaseOwner()
    }

    @Test func smartUsesChannelsOnTheDonatedConnectionThroughTheDecimalThreshold() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, limit: 2,
            primaryRole: .donatedConnection, strategy: .smart)
        enqueue(
            [SFTPConcurrencyStrategy.smartConnectionThreshold, SFTPConcurrencyStrategy.smartConnectionThreshold],
            session: session, coordinator: coordinator)
        try await eventually { await harness.started == 2 }
        #expect(await harness.opens == 0)
        #expect(await harness.siblingChannels == 1)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        await session.releaseOwner()
    }

    @Test func smartUsesAnotherConnectionAboveTheDecimalThreshold() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, limit: 2,
            primaryRole: .donatedConnection, strategy: .smart)
        let large = SFTPConcurrencyStrategy.smartConnectionThreshold + 1
        enqueue([large, large], session: session, coordinator: coordinator)
        try await eventually { await harness.started == 2 }
        #expect(await harness.opens == 1)
        #expect(await harness.siblingChannels == 0)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        await session.releaseOwner()
    }

    @Test func terminalFallbackNeverRetriesConnectionsForLargeFiles() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, limit: 3,
            primaryRole: .terminalFallback, strategy: .smart)
        let large = SFTPConcurrencyStrategy.smartConnectionThreshold + 1
        enqueue([large, large, large], session: session, coordinator: coordinator)
        try await eventually { await harness.started == 3 }
        #expect(await harness.opens == 0)
        #expect(await harness.siblingChannels == 2)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        await session.releaseOwner()
    }

    @Test func emptyCredentialsCanOpenParallelConnectionsWithinTheLimits() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness, limit: 2)
        enqueue(3, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 2 }
        #expect(await harness.opens == 2)
        #expect(await harness.maximumActive == 2)
        #expect(await harness.emptyCredentials)
        await session.releaseOwner()
        #expect(await primary.disconnects == 0)
        await harness.releaseOne()
        try await eventually { await harness.started == 3 }
        #expect(await harness.maximumActive == 2)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        #expect(await primary.disconnects == 1)
    }

    @Test func laterConnectionFailureKeepsRunningFilesAndFallsBackToChannels() async throws {
        let harness = TransferSessionHarness(behaviors: [.success, .interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness, limit: 2)
        enqueue(4, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 2 }
        #expect(await harness.opens == 2)
        await harness.releaseAll()
        try await eventually { await harness.started == 4 }
        #expect(coordinator.activeCount == 2)
        #expect(await harness.siblingChannels == 3)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        #expect(await harness.opens == 2)
        await session.releaseOwner()
        #expect(await primary.disconnects == 1)
    }

    @Test func cancellingAProbeDoesNotCacheASerialResult() async throws {
        let harness = TransferSessionHarness(behaviors: [.waitForCancellation, .success])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(primary: primary, harness: harness)
        let ids = enqueue(2, session: session, coordinator: coordinator)
        try await eventually { await harness.opens == 1 }
        coordinator.cancel(ids[0])
        try await eventually { await harness.started == 1 }
        #expect(await harness.opens == 2)
        #expect(coordinator.sftpTransfers.first { $0.id == ids[0] }?.state == .cancelled)
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        await session.releaseOwner()
    }

    @Test func preflightConnectionIsUsedWithoutReauthentication() async throws {
        let harness = TransferSessionHarness(behaviors: [.interactive])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, primaryRole: .donatedConnection)
        enqueue(1, session: session, coordinator: coordinator)
        try await eventually { await harness.started == 1 }
        #expect(await harness.opens == 0)
        await session.releaseOwner()
        #expect(await primary.disconnects == 0)
        await harness.releaseOne()
        try await eventually { coordinator.activeCount == 0 }
        #expect(await primary.disconnects == 1)
    }

    @Test func pausedTransfersReleaseTheDetachedPrimaryAndResumeSilently() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let (session, coordinator) = fixture(
            primary: primary, harness: harness, primaryRole: .donatedConnection)
        let id = enqueue(1, session: session, coordinator: coordinator)[0]
        try await eventually { await harness.started == 1 }
        await session.releaseOwner()
        coordinator.pause(id)
        try await eventually { coordinator.activeCount == 0 }
        #expect(coordinator.sftpTransfers.first?.state == .paused)
        #expect(await primary.disconnects == 1)
        coordinator.resume(id)
        try await eventually { await harness.started == 2 }
        #expect(await harness.policies == [.forbidden])
        await harness.releaseOne()
        try await eventually { coordinator.activeCount == 0 }
        #expect(coordinator.sftpTransfers.first?.state == .completed)
    }

    @Test func terminalBatchUsesFiveConnectionsAndSurvivesItsTemporarySessionClosing() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let primary = TransferSessionClient(harness: harness, primary: true)
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "terminal", port: 22, username: "user", credentials: [], expectedHostKeys: [])
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { TransferSessionClient(harness: harness) },
            globalLimit: 15, perHostLimit: 5, strategy: .connectionsPreferred)
        let upload = SFTPSessionModel(
            hostID: configuration.hostID, initialPath: "/destination", client: primary,
            configuration: configuration, primaryRole: .donatedConnection)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try (0..<7).map { index in
            let file = directory.appending(path: "file-\(index)")
            try Data([1]).write(to: file)
            return file
        }
        await upload.prepareUpload(files)
        await upload.enqueuePending(policy: .replace, coordinator: coordinator)
        upload.disconnect()
        try await eventually { await harness.started == 5 }
        #expect(await harness.maximumActive == 5)
        #expect(await harness.opens == 4)
        #expect(await harness.policies.allSatisfy { $0 == .forbidden })
        #expect(await primary.disconnects == 0)
        await harness.releaseOne()
        try await eventually { await harness.started == 6 }
        #expect(await harness.maximumActive == 5)
        await harness.releaseAll()
        try await eventually { await harness.started == 7 }
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .completed })
        #expect(await primary.disconnects == 1)
    }

    @Test func twoTerminalSessionsForOneHostShareTheSameFiveTransferLimit() async throws {
        let harness = TransferSessionHarness(behaviors: [])
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { TransferSessionClient(harness: harness) },
            globalLimit: 15, perHostLimit: 5, strategy: .connectionsPreferred)
        let configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "same-host", port: 22, username: "user", credentials: [], expectedHostKeys: [])
        let sessions = (0..<2).map { _ in
            SFTPTransferSession(
                configuration: configuration, client: TransferSessionClient(harness: harness),
                primaryRole: .donatedConnection)
        }
        for session in sessions { enqueue(4, session: session, coordinator: coordinator) }
        try await eventually { await harness.started == 5 }
        #expect(coordinator.activeCount == 5)
        #expect(await harness.maximumActive == 5)
        for session in sessions { await session.releaseOwner() }
        await harness.releaseAll()
        try await eventually { await harness.started == 8 }
        await harness.releaseAll()
        try await eventually { coordinator.activeCount == 0 }
        #expect(await harness.maximumActive == 5)
    }

    private func fixture(
        primary: TransferSessionClient, harness: TransferSessionHarness, limit: Int = 4,
        primaryRole: SFTPTransferPrimaryRole = .control,
        strategy: SFTPConcurrencyStrategy = .connectionsPreferred
    ) -> (SFTPTransferSession, SFTPTransferCoordinator) {
        let session = SFTPTransferSession(
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "fixture", port: 22, username: "user",
                credentials: [], expectedHostKeys: []),
            client: primary, primaryRole: primaryRole)
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { TransferSessionClient(harness: harness) },
            globalLimit: limit, perHostLimit: limit, strategy: strategy)
        return (session, coordinator)
    }

    @discardableResult
    private func enqueue(_ count: Int, session: SFTPTransferSession, coordinator: SFTPTransferCoordinator) -> [UUID] {
        enqueue(Array(repeating: 1, count: count), session: session, coordinator: coordinator)
    }

    @discardableResult
    private func enqueue(
        _ byteCounts: [Int64], session: SFTPTransferSession, coordinator: SFTPTransferCoordinator
    ) -> [UUID] {
        byteCounts.enumerated().map { index, byteCount in
            coordinator.enqueue(
                direction: .upload, batchID: UUID(),
                localURL: URL(fileURLWithPath: "/tmp/termind-test-\(index)"), remotePath: "/file-\(index)",
                byteCount: byteCount, hostID: session.configuration.hostID, connection: .session(session),
                scopedRoot: URL(fileURLWithPath: "/tmp"), overwrite: true)
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }
}

private actor UploadConnectionResolutionHarness {
    enum Independent { case success, interactionRequired, cancelled }

    let independent: Independent
    private(set) var fallbacks = 0
    private let client: TransferSessionClient

    init(independent: Independent) {
        self.independent = independent
        client = TransferSessionClient(harness: TransferSessionHarness(behaviors: []))
    }

    func connectIndependent() async throws -> any SFTPClientProtocol {
        switch independent {
        case .success: client
        case .interactionRequired: throw SSHInteractionRequired()
        case .cancelled: throw CancellationError()
        }
    }

    func openTerminalChannel() -> any SFTPClientProtocol {
        fallbacks += 1
        return client
    }
}

private actor TransferSessionHarness {
    enum Behavior: Sendable { case success, interactive, waitForCancellation }
    private var behaviors: [Behavior]
    private(set) var policies: [SSHInteractionPolicy] = []
    private(set) var emptyCredentials = true
    private(set) var opens = 0
    private(set) var started = 0
    private(set) var maximumActive = 0
    private(set) var siblingChannels = 0
    private var pending: [(UUID, CheckedContinuation<Void, any Error>)] = []

    init(behaviors: [Behavior]) { self.behaviors = behaviors }

    func connect(_ request: SSHConnectionRequest) async throws {
        opens += 1
        policies.append(request.interactionPolicy)
        emptyCredentials = emptyCredentials && request.configuration.credentials.isEmpty
        let behavior = behaviors.isEmpty ? .success : behaviors.removeFirst()
        switch behavior {
        case .success: break
        case .interactive: throw SSHInteractionRequired()
        case .waitForCancellation: try await Task.sleep(for: .seconds(30))
        }
    }

    func openSibling() { siblingChannels += 1 }

    func run(cancellation: TransferCancellationToken) async throws {
        let id = UUID()
        let observer = cancellation.observeCancellation { [weak self] in
            Task { await self?.cancel(id) }
        }
        defer { cancellation.removeObserver(observer) }
        guard !cancellation.isCancelled else { throw SFTPError.cancelled }
        try await withCheckedThrowingContinuation { continuation in
            started += 1
            pending.append((id, continuation))
            maximumActive = max(maximumActive, pending.count)
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).1.resume(throwing: SFTPError.cancelled)
    }

    func releaseOne() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume()
    }

    func releaseAll() {
        let values = pending
        pending.removeAll()
        for value in values { value.1.resume() }
    }
}

private actor TransferSessionClient: SFTPClientProtocol {
    let harness: TransferSessionHarness
    let primary: Bool
    private(set) var disconnects = 0
    init(harness: TransferSessionHarness, primary: Bool = false) {
        self.harness = harness
        self.primary = primary
    }
    func openSiblingChannel() async throws -> any SFTPClientProtocol {
        await harness.openSibling()
        return TransferSessionClient(harness: harness)
    }
    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {
        try await connect(
            using: SSHConnectionRequest(configuration: configuration), progress: progress, connectionFailure: nil)
    }
    func connect(
        using request: SSHConnectionRequest, progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws { try await harness.connect(request) }
    func disconnect() async { disconnects += 1 }
    func homeDirectory() async throws -> String { "/" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { try await harness.run(cancellation: cancellation) }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { try await harness.run(cancellation: cancellation) }
    func copyFile(
        from sourcePath: String, to destinationPath: String, on destination: any SFTPClientProtocol,
        byteCount: Int64, overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        #expect(destination as? TransferSessionClient === self)
        try await harness.run(cancellation: cancellation)
    }
}

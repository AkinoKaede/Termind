import Foundation
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import Termind

@Suite
@MainActor
struct SFTPFeatureTests {
    @Test
    func transferSummaryWeightsProgressByBytesAndCountsFailures() {
        let host = Host(name: "Host", host: "host.example")
        let first = SFTPTransfer(
            hostID: host.id, direction: .upload,
            localPath: "/tmp/first", remotePath: "/srv/first",
            byteCount: 100, transferredBytes: 25, state: .running
        )
        let second = SFTPTransfer(
            hostID: host.id, direction: .upload,
            localPath: "/tmp/second", remotePath: "/srv/second",
            byteCount: 300, transferredBytes: 0, state: .queued
        )
        let failed = SFTPTransfer(
            hostID: host.id, direction: .download,
            localPath: "/tmp/failed", remotePath: "/srv/failed",
            byteCount: 10, transferredBytes: 4, state: .failed("Network lost")
        )
        let store = HostStore(
            hosts: [host], sftpTransfers: [first, second, failed]
        )
        let coordinator = SFTPTransferCoordinator(store: store)

        #expect(coordinator.summary.activeCount == 2)
        #expect(coordinator.summary.failedCount == 1)
        #expect(coordinator.summary.aggregateProgress == 0.0625)
    }

    @Test
    func clearingTransferCenterHistoryPreservesUnfinishedWork() {
        let host = Host(name: "Host", host: "host.example")
        let queued = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/queued", remotePath: "/queued",
            state: .queued
        )
        let running = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/running", remotePath: "/running",
            state: .running
        )
        let completed = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/completed", remotePath: "/completed",
            state: .completed
        )
        let cancelled = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/cancelled", remotePath: "/cancelled",
            state: .cancelled
        )
        let failed = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/failed", remotePath: "/failed",
            state: .failed("Permission denied")
        )
        let store = HostStore(
            hosts: [host],
            sftpTransfers: [queued, running, completed, cancelled, failed]
        )
        let coordinator = SFTPTransferCoordinator(store: store)

        coordinator.clearFinished()

        #expect(store.sftpTransfers.map(\.id) == [queued.id, running.id])
    }

    @Test
    func remotePathsNormalizeWithoutEscapingRoot() {
        #expect(RemotePath.normalized(" /srv//releases/../current/ ") == "/srv/current")
        #expect(RemotePath.normalized("../../etc") == "/etc")
        #expect(RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.parent(of: "/var/log") == "/var")
        #expect(RemotePath.join("/", "tmp") == "/tmp")
    }

    @Test
    func crossHostCopyBelongsToBothHostsAndDrivesBothStatusDots() {
        let source = Host(name: "Source", host: "source.example")
        let destination = Host(name: "Destination", host: "destination.example")
        let sftpTransfer = SFTPTransfer(
            hostID: destination.id,
            sourceHostID: source.id,
            destinationHostID: destination.id,
            direction: .copy,
            localPath: "/source/README.md",
            remotePath: "/destination/README.md",
            state: .running
        )
        let store = HostStore(
            hosts: [source, destination], sftpTransfers: [sftpTransfer]
        )

        #expect(store.sftpTransfers(for: source.id).map(\.id) == [sftpTransfer.id])
        #expect(store.sftpTransfers(for: destination.id).map(\.id) == [sftpTransfer.id])
        #expect(store.status(of: source.id) == .connected)
        #expect(store.status(of: destination.id) == .connected)
    }

    @Test
    func keepBothNamesPreserveExtensions() {
        #expect(RemotePath.keepBothCandidate(for: "/tmp/archive.tar", index: 2) == "/tmp/archive.2.tar")
        #expect(RemotePath.keepBothCandidate(for: "/tmp/folder", index: 3) == "/tmp/folder.3")
    }

    @Test
    func remoteFileExposesUnixPermissions() {
        let file = RemoteFile(
            path: "/tmp/tool", name: "tool", kind: .file, size: 12,
            modifiedAt: nil, permissions: 0o754, ownerUID: 501, ownerGID: 20
        )
        #expect(file.permissionDescription == "-rwxr-xr--")
        #expect(file.id == "/tmp/tool")
    }

    @Test
    func hostDefaultsToRemoteHomeForSFTPSession() {
        let host = Host(name: "Server", host: "server.example")
        #expect(host.sftpSessionInitialPath.isEmpty)
        let pane = Pane.sftpSession(host: host)
        guard case .sftpSession(let sftpSession) = pane.content else {
            Issue.record("Expected SFTP session pane")
            return
        }
        #expect(sftpSession.path == "/")
    }

    @Test
    func applicationTerminationClosesRegisteredWindows() {
        let app = AppModel(hosts: HostStore())
        let window = WindowModel()
        app.registerWindow(window)

        app.shutdownForTermination()

        #expect(window.tabs.isEmpty)
    }

    @Test
    func emptyInitialPathResolvesRemoteHomeOnlyOnce() async throws {
        let client = ManifestSFTPClient(entries: [:], home: "/home/deploy/")
        let sftpSession = SFTPSessionModel(hostID: UUID(), initialPath: "")

        try await sftpSession.resolveInitialPathIfNeeded(using: client)
        try await sftpSession.resolveInitialPathIfNeeded(using: client)

        #expect(sftpSession.path == "/home/deploy")
        #expect(sftpSession.pathText == "/home/deploy")
        #expect(await client.homeDirectoryRequestCount == 1)
    }

    @Test
    func silentRefreshCommitsOnlySuccessfulSnapshots() async {
        let initial = remoteFile(path: "/home/old.txt", kind: .file)
        let updated = remoteFile(path: "/home/new.txt", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([initial]), .failure, .success([updated])])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpSession.reload(silently: true)
        #expect(sftpSession.files == [initial])
        await sftpSession.reload(silently: true)
        #expect(sftpSession.files == [initial])
        #expect(sftpSession.operationError == nil)
        await sftpSession.reload(silently: true)
        #expect(sftpSession.files == [updated])
    }

    @Test
    func automaticRefreshRepeatsUntilDisconnect() async {
        let client = SnapshotSFTPClient(responses: [.success([])])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration,
            automaticRefreshInterval: .milliseconds(10)
        )

        sftpSession.startAutomaticRefresh()
        while await client.listRequestCount < 2 { await Task.yield() }
        sftpSession.disconnect()
        let countAfterDisconnect = await client.listRequestCount
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await client.listRequestCount == countAfterDisconnect)
    }

    @Test
    func connectionLossStartsReconnectWithoutClearingDirectorySnapshot() async {
        let host = Host(name: "Files", host: "files.example")
        let existing = remoteFile(path: "/home/existing.txt", kind: .file)
        let client = SnapshotSFTPClient(
            responses: [.success([existing]), .connectionLost]
        )
        let store = HostStore(hosts: [host])
        let sftpSession = SFTPSessionModel(
            hostID: host.id, initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        sftpSession.bindStatus(to: store)

        await sftpSession.reload()
        await sftpSession.reload(silently: true)

        #expect(sftpSession.status == .reconnecting)
        #expect(sftpSession.reconnectState?.attempt == 1)
        #expect(sftpSession.connectionJourney.mode == .reconnection)
        #expect(sftpSession.connectionJourney.isPresented)
        #expect(sftpSession.files == [existing])
        #expect(sftpSession.path == "/home")
        sftpSession.disconnect()
    }

    @Test
    func ordinarySFTPFailureDoesNotStartReconnect() async {
        let host = Host(name: "Files", host: "files.example")
        let client = SnapshotSFTPClient(responses: [.failure])
        let store = HostStore(hosts: [host])
        let sftpSession = SFTPSessionModel(
            hostID: host.id, initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        sftpSession.bindStatus(to: store)

        await sftpSession.reload()

        #expect(sftpSession.status == .connected)
        #expect(sftpSession.reconnectState == nil)
        #expect(sftpSession.operationError == "Refresh failed")
        sftpSession.disconnect()
    }

    @Test
    func successfulUploadRefreshesTheVisibleDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("report.txt")
        try Data("termind".utf8).write(to: localFile)
        let uploaded = remoteFile(path: "/home/report.txt", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([uploaded])])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { client }

        await sftpSession.prepareUpload([localFile])
        await sftpSession.enqueuePending(policy: .replace, coordinator: coordinator)
        for _ in 0..<100 where sftpSession.files.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(sftpSession.files == [uploaded])
    }

    @Test
    func coordinatorHonorsGlobalAndPerHostLimits() async {
        let hostA = UUID()
        let hostB = UUID()
        let store = HostStore()
        let gate = SFTPTransferClientGate()
        let coordinator = SFTPTransferCoordinator(store: store) { FakeSFTPTransferClient(gate: gate) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        for index in 0..<5 {
            let isA = index < 4
            let configuration = SSHConnectionConfiguration(
                hostID: isA ? hostA : hostB, host: isA ? "a" : "b",
                port: 22, username: "user", credentials: [],
                expectedHostKeys: [
                    SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "fingerprint")
                ]
            )
            coordinator.enqueue(
                direction: .download, batchID: UUID(),
                localURL: root.appendingPathComponent("file-\(index)"),
                remotePath: "/file-\(index)", byteCount: 1,
                hostID: isA ? hostA : hostB, configuration: configuration,
                scopedRoot: root, overwrite: true
            )
        }
        await gate.waitForStarts(3)
        #expect(await gate.maximumActive == 3)
        #expect(await gate.maximumActive(for: "a") == 2)
        await gate.releaseAll()
    }

    @Test
    func borrowedConnectionRunsSeriallyWithoutReconnect() async {
        let hostID = UUID()
        let connectionID = UUID()
        let store = HostStore()
        let gate = SFTPTransferClientGate()
        let client = BorrowedSFTPTransferClient(gate: gate)
        let coordinator = SFTPTransferCoordinator(
            store: store, globalLimit: 4, perHostLimit: 4
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())

        for index in 0..<2 {
            coordinator.enqueue(
                direction: .download, batchID: UUID(),
                localURL: root.appendingPathComponent("borrowed-\(index)"),
                remotePath: "/borrowed-\(index)", byteCount: 1,
                hostID: hostID, connection: .borrowed(id: connectionID, client: client),
                scopedRoot: root, overwrite: true
            )
        }

        await gate.waitForStarts(1)
        #expect(await gate.maximumActive == 1)
        #expect(coordinator.activeCount == 1)
        await gate.releaseNext()
        await gate.waitForStarts(2)
        #expect(await gate.maximumActive == 1)
        await gate.releaseAll()

        while coordinator.activeCount > 0 { await Task.yield() }
        #expect(await client.connectCount == 0)
        #expect(await client.disconnectCount == 0)
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .completed })
    }

    @Test
    func increasingLimitsImmediatelyStartsQueuedTransfers() async {
        let gate = SFTPTransferClientGate()
        let coordinator = SFTPTransferCoordinator(
            store: HostStore(), clientFactory: { FakeSFTPTransferClient(gate: gate) },
            globalLimit: 1, perHostLimit: 1
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        for index in 0..<2 {
            let hostID = UUID()
            coordinator.enqueue(
                direction: .download, batchID: UUID(),
                localURL: root.appendingPathComponent("limit-\(index)"),
                remotePath: "/limit-\(index)", byteCount: 1, hostID: hostID,
                configuration: makeTestConfiguration(hostID: hostID, host: "host-\(index)"),
                scopedRoot: root, overwrite: true
            )
        }
        await gate.waitForStarts(1)

        coordinator.updateLimits(global: 2, perHost: 2)

        await gate.waitForStarts(2)
        #expect(await gate.maximumActive == 2)
        await gate.releaseAll()
    }

    @Test
    func coordinatorReportsCompletionForOpenAfterDownload() async {
        let store = HostStore()
        let client = ManifestSFTPClient(entries: [:])
        let coordinator = SFTPTransferCoordinator(store: store) { client }
        let root = FileManager.default.temporaryDirectory
        var completionState: SFTPTransfer.State?

        coordinator.enqueue(
            direction: .download, batchID: UUID(),
            localURL: root.appendingPathComponent(UUID().uuidString),
            remotePath: "/document.txt", byteCount: 4, hostID: UUID(),
            configuration: testConfiguration, scopedRoot: root, overwrite: false
        ) { state in
            completionState = state
        }

        while coordinator.sftpTransfers.first?.state == .queued
            || coordinator.sftpTransfers.first?.state == .running
        {
            await Task.yield()
        }
        #expect(completionState == .completed)
    }

    @Test
    func sshAndSFTPSessionStatusesAggregateForHostDots() {
        let hostID = UUID()
        let sshSessionID = UUID()
        let sftpSessionID = UUID()
        let store = HostStore()

        store.setConnectionStatus(.connected, connectionID: sshSessionID, hostID: hostID)
        store.setConnectionStatus(.connecting, connectionID: sftpSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .connected)

        store.setConnectionStatus(.disconnected, connectionID: sshSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .connecting)

        store.setConnectionStatus(.reconnecting, connectionID: sftpSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .reconnecting)

        store.setConnectionStatus(.connected, connectionID: sftpSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .connected)

        store.setConnectionStatus(.disconnected, connectionID: sftpSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .disconnected)
    }

    @Test
    func sftpSessionPublishesItsStatusToHostStore() {
        let hostID = UUID()
        let store = HostStore()
        let sftpSession = SFTPSessionModel(
            hostID: hostID, initialPath: "/home",
            client: SnapshotSFTPClient(responses: [.success([])]),
            configuration: testConfiguration
        )

        sftpSession.bindStatus(to: store)
        #expect(store.status(of: hostID) == .connected)

        sftpSession.disconnect()
        #expect(store.status(of: hostID) == .disconnected)
    }

    @Test
    func multipleSelectionPreservesVisibleOrder() async {
        let first = remoteFile(path: "/home/a.txt", kind: .file)
        let second = remoteFile(path: "/home/b.txt", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([first, second])])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpSession.reload(silently: true)
        sftpSession.selection = [second.id, first.id]

        #expect(sftpSession.selectedFiles == [first, second])
    }

    @Test(arguments: [".bashrc", "README.md"])
    func finderDragRepresentationPreservesExactBasename(_ name: String) async {
        let client = WritingSFTPClient()
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { client }
        let file = remoteFile(path: "/home/\(name)", kind: .file)
        let provider = SFTPBrowserView.promisedFileProvider(
            for: file, sftpSession: sftpSession, coordinator: coordinator
        )

        let representedName = await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.data.identifier) { url, _ in
                continuation.resume(returning: url?.lastPathComponent)
            }
        }

        #expect(representedName != nil)
        #expect(provider.suggestedName == name)
    }

    @Test
    func remoteCopyManifestPreservesHierarchyAndEmptyDirectories() async throws {
        let sourceHostID = UUID()
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let empty = remoteFile(path: "/source/bundle/empty", kind: .directory)
        let readme = remoteFile(path: "/source/bundle/README.md", kind: .file, size: 4)
        let client = TreeSFTPClient(listings: [
            bundle.path: [empty, readme],
            empty.path: [],
        ])
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { client }
        let source = SFTPRemoteCopySource(
            hostID: sourceHostID,
            configuration: makeTestConfiguration(hostID: sourceHostID, host: "source"),
            files: [bundle]
        )
        let payload = coordinator.registerRemoteCopySource(source)

        let manifest = try await coordinator.remoteManifest(for: payload)

        #expect(
            manifest.entries.map(\.relativePath) == [
                "bundle", "bundle/empty", "bundle/README.md",
            ])
        #expect(
            manifest.entries.filter(\.isDirectory).map(\.relativePath) == [
                "bundle", "bundle/empty",
            ])
    }

    @Test
    func remoteCopyPreflightFindsTargetConflicts() async {
        let sourceHostID = UUID()
        let targetHostID = UUID()
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let readme = remoteFile(path: "/source/bundle/README.md", kind: .file, size: 4)
        let sourceClient = TreeSFTPClient(listings: [bundle.path: [readme]])
        let targetClient = ManifestSFTPClient(entries: [
            "/incoming/bundle/README.md": remoteFile(
                path: "/incoming/bundle/README.md", kind: .file, size: 3
            )
        ])
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { sourceClient }
        let payload = coordinator.registerRemoteCopySource(
            SFTPRemoteCopySource(
                hostID: sourceHostID,
                configuration: makeTestConfiguration(hostID: sourceHostID, host: "source"),
                files: [bundle]
            ))
        let target = SFTPSessionModel(
            hostID: targetHostID, initialPath: "/incoming", client: targetClient,
            configuration: makeTestConfiguration(hostID: targetHostID, host: "target")
        )

        await target.prepareRemoteCopy(payload, coordinator: coordinator)

        #expect(target.pendingRemoteCopyBatch?.remoteDirectories == ["/incoming/bundle"])
        #expect(target.pendingRemoteCopyBatch?.jobs.first?.destinationPath == "/incoming/bundle/README.md")
        #expect(target.pendingRemoteCopyBatch?.jobs.first?.hasConflict == true)
        #expect(target.conflictCount == 1)
    }

    @Test
    func remoteCopyStreamsThroughSocketWithoutTemporaryFile() async throws {
        let sourceHostID = UUID()
        let targetHostID = UUID()
        let state = RemoteCopyTrackingState()
        let coordinator = SFTPTransferCoordinator(store: HostStore()) {
            RemoteCopyTrackingClient(state: state)
        }
        coordinator.enqueueRemoteCopy(
            batchID: UUID(),
            sourcePath: "/source/README.md", sourceHostID: sourceHostID,
            sourceConfiguration: makeTestConfiguration(hostID: sourceHostID, host: "source"),
            destinationPath: "/target/README.md", destinationHostID: targetHostID,
            destinationConfiguration: makeTestConfiguration(hostID: targetHostID, host: "target"),
            byteCount: 4, overwrite: false
        )

        for _ in 0..<200 {
            if coordinator.sftpTransfers.count == 1,
                coordinator.sftpTransfers.allSatisfy({ $0.state == .completed })
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await state.events == ["copy:source:/source/README.md->target:/target/README.md"])
        #expect(coordinator.sftpTransfers.map(\.direction) == [.copy])
    }

    @Test
    func uploadPreflightCountsATopLevelFileConflictOnce() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localFile = root.appendingPathComponent("report.txt")
        try Data("termind".utf8).write(to: localFile)

        let client = ManifestSFTPClient(entries: [
            "/incoming/report.txt": remoteFile(path: "/incoming/report.txt", kind: .file)
        ])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )

        await sftpSession.prepareUpload([localFile])

        #expect(sftpSession.pendingBatch?.conflictCount == 1)
        #expect(sftpSession.pendingBatch?.jobs.count == 1)
        #expect(sftpSession.pendingBatch?.jobs.first?.hasConflict == true)
    }

    @Test
    func skippingAConflictingUploadDirectorySkipsItsWholeSubtree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = root.appendingPathComponent("bundle", isDirectory: true)
        let nested = upload.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("termind".utf8).write(to: nested.appendingPathComponent("payload.txt"))

        let client = ManifestSFTPClient(
            entries: ["/incoming/bundle": remoteFile(path: "/incoming/bundle", kind: .file)],
            rejectedAttributePrefix: "/incoming/bundle/"
        )
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { client }

        await sftpSession.prepareUpload([upload])
        #expect(sftpSession.pendingBatch?.conflictCount == 1)
        #expect(sftpSession.operationError == nil)

        await sftpSession.enqueuePending(policy: .skip, coordinator: coordinator)

        #expect(coordinator.sftpTransfers.isEmpty)
        #expect(await client.createdDirectories.isEmpty)
        #expect(await client.rejectedAttributeRequestCount == 0)
    }

    @Test
    func keepingBothForAConflictingUploadDirectoryRemapsItsWholeSubtree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let upload = root.appendingPathComponent("bundle", isDirectory: true)
        let nested = upload.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("termind".utf8).write(to: nested.appendingPathComponent("payload.txt"))

        let client = ManifestSFTPClient(
            entries: ["/incoming/bundle": remoteFile(path: "/incoming/bundle", kind: .file)],
            rejectedAttributePrefix: "/incoming/bundle/"
        )
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostStore()) { client }

        await sftpSession.prepareUpload([upload])
        await sftpSession.enqueuePending(policy: .keepBoth, coordinator: coordinator)

        #expect(coordinator.sftpTransfers.map(\.remotePath) == ["/incoming/bundle.2/nested/payload.txt"])
        #expect(
            await client.createdDirectories == [
                "/incoming/bundle.2", "/incoming/bundle.2/nested",
            ])
        #expect(await client.rejectedAttributeRequestCount == 0)
    }
}

private let testConfiguration = makeTestConfiguration(hostID: UUID(), host: "example.test")

private func makeTestConfiguration(hostID: UUID, host: String) -> SSHConnectionConfiguration {
    SSHConnectionConfiguration(
        hostID: hostID, host: host, port: 22, username: "user", credentials: [],
        expectedHostKeys: [
            SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "fingerprint")
        ]
    )
}

private func remoteFile(
    path: String, kind: RemoteFile.Kind, size: Int64 = 0
) -> RemoteFile {
    RemoteFile(
        path: path, name: (path as NSString).lastPathComponent, kind: kind,
        size: size, modifiedAt: nil, permissions: 0o644, ownerUID: 501, ownerGID: 20
    )
}

private actor SFTPTransferClientGate {
    private var active = 0
    private var maximum = 0
    private var starts = 0
    private var activeByHost: [String: Int] = [:]
    private var maximumByHost: [String: Int] = [:]
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var maximumActive: Int { maximum }
    func maximumActive(for host: String) -> Int { maximumByHost[host, default: 0] }

    func enter(host: String) async {
        active += 1
        activeByHost[host, default: 0] += 1
        starts += 1
        maximum = max(maximum, active)
        maximumByHost[host] = max(maximumByHost[host, default: 0], activeByHost[host, default: 0])
        await withCheckedContinuation { continuations.append($0) }
        active -= 1
        activeByHost[host, default: 1] -= 1
    }

    func waitForStarts(_ count: Int) async {
        while starts < count { await Task.yield() }
    }

    func releaseAll() {
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor FakeSFTPTransferClient: SFTPClientProtocol {
    let gate: SFTPTransferClientGate
    private var host = ""
    init(gate: SFTPTransferClientGate) { self.gate = gate }
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws { host = configuration.host }
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/Users/test" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { await gate.enter(host: host) }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { await gate.enter(host: host) }
}

private actor BorrowedSFTPTransferClient: SFTPClientProtocol {
    let gate: SFTPTransferClientGate
    private(set) var connectCount = 0
    private(set) var disconnectCount = 0

    init(gate: SFTPTransferClientGate) { self.gate = gate }
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws { connectCount += 1 }
    func disconnect() async { disconnectCount += 1 }
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { await gate.enter(host: "borrowed") }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { await gate.enter(host: "borrowed") }
}

private actor ManifestSFTPClient: SFTPClientProtocol {
    private let entries: [String: RemoteFile]
    private let rejectedAttributePrefix: String?
    private let home: String
    private(set) var createdDirectories: [String] = []
    private(set) var rejectedAttributeRequestCount = 0
    private(set) var homeDirectoryRequestCount = 0

    init(
        entries: [String: RemoteFile], rejectedAttributePrefix: String? = nil,
        home: String = "/Users/test"
    ) {
        self.entries = entries
        self.rejectedAttributePrefix = rejectedAttributePrefix
        self.home = home
    }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String {
        homeDirectoryRequestCount += 1
        return home
    }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? {
        if let rejectedAttributePrefix, path.hasPrefix(rejectedAttributePrefix) {
            rejectedAttributeRequestCount += 1
            throw SFTPError.operation("Unexpected descendant stat: \(path)")
        }
        return entries[path]
    }
    func createDirectory(at path: String) async throws { createdDirectories.append(path) }
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

private actor SnapshotSFTPClient: SFTPClientProtocol {
    enum Response: Sendable {
        case success([RemoteFile])
        case failure
        case connectionLost
    }

    private var responses: [Response]
    private(set) var listRequestCount = 0

    init(responses: [Response]) { self.responses = responses }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        listRequestCount += 1
        let response = responses.count > 1 ? responses.removeFirst() : responses[0]
        switch response {
        case .success(let files): return files
        case .failure: throw SFTPError.operation("Refresh failed")
        case .connectionLost: throw SFTPError.connectionLost("Network lost")
        }
    }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
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

private actor WritingSFTPClient: SFTPClientProtocol {
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
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
    ) async throws {
        try Data("termind".utf8).write(to: localURL)
    }
}

private actor TreeSFTPClient: SFTPClientProtocol {
    let listings: [String: [RemoteFile]]

    init(listings: [String: [RemoteFile]]) {
        self.listings = listings
    }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { listings[path] ?? [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
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

private actor RemoteCopyTrackingState {
    private(set) var events: [String] = []
    func append(_ event: String) { events.append(event) }
}

private actor RemoteCopyTrackingClient: SFTPClientProtocol {
    let state: RemoteCopyTrackingState
    private var host = ""

    init(state: RemoteCopyTrackingState) { self.state = state }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws { host = configuration.host }
    func disconnect() async {}
    func connectedHost() -> String { host }
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [] }
    func attributes(at path: String) async throws -> RemoteFile? { nil }
    func createDirectory(at path: String) async throws {}
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws {}
    func removeDirectory(at path: String) async throws {}
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        _ = try Data(contentsOf: localURL)
        await state.append("upload:\(host):\(remotePath)")
    }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try FileManager.default.createDirectory(
            at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("termind".utf8).write(to: localURL)
        await state.append("download:\(host):\(remotePath)")
    }
    func copyFile(
        from sourcePath: String,
        to destinationPath: String,
        on destination: any SFTPClientProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        guard let destination = destination as? RemoteCopyTrackingClient else {
            throw SFTPError.operation("Unexpected test destination")
        }
        let destinationHost = await destination.connectedHost()
        await state.append(
            "copy:\(host):\(sourcePath)->\(destinationHost):\(destinationPath)"
        )
        progress(
            SFTPProgress(
                completedBytes: byteCount, totalBytes: byteCount, bytesPerSecond: 0
            ))
    }
}

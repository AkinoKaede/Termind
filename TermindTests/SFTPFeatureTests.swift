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
        let store = HostLibraryModel(
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
        let store = HostLibraryModel(
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
        #expect(RemotePath.components(of: "/var/log/nginx").map(\.path) == [
            "/", "/var", "/var/log", "/var/log/nginx",
        ])
        #expect(RemotePath.displayed("/home/deploy", home: .resolved("/home/deploy")) == "~")
        #expect(RemotePath.displayed("/home/deploy/app", home: .resolved("/home/deploy")) == "~/app")
        #expect(RemotePath.displayed("/home/deployer", home: .resolved("/home/deploy")) == "/home/deployer")
        #expect(RemotePath.displayed("/var/log", home: .unavailable) == "/var/log")
        #expect(RemotePath.displayed("/var/log", home: .resolved("/")) == "~/var/log")
        #expect(
            RemotePath.displayedComponents(
                of: "/home/deploy/app/logs", home: .resolved("/home/deploy")
            ).map(\.name) == ["~", "app", "logs"]
        )
    }

    @Test
    func sftpDirectorySortingKeepsFoldersFirstAndUsesStableNames() async {
        let older = Date(timeIntervalSinceReferenceDate: 100)
        let newer = Date(timeIntervalSinceReferenceDate: 200)
        let folderZ = remoteFile(path: "/home/z-folder", kind: .directory, modifiedAt: older)
        let folderA = remoteFile(path: "/home/a-folder", kind: .directory, modifiedAt: newer)
        let missingDate = remoteFile(path: "/home/undated.log", kind: .file, size: 50)
        let small = remoteFile(
            path: "/home/small.txt", kind: .file, size: 10, modifiedAt: older
        )
        let large = remoteFile(
            path: "/home/large.txt", kind: .file, size: 100, modifiedAt: newer
        )
        let client = SnapshotSFTPClient(
            responses: [.success([folderZ, missingDate, large, folderA, small])]
        )
        let session = SFTPSessionModel(hostID: UUID(), initialPath: "/home", client: client)

        await session.reload(silently: true)
        #expect(session.filteredFiles.map(\.name) == [
            "a-folder", "z-folder", "large.txt", "small.txt", "undated.log",
        ])

        session.sort(by: .modified)
        #expect(session.sortDirection == .descending)
        #expect(session.filteredFiles.map(\.name) == [
            "a-folder", "z-folder", "large.txt", "small.txt", "undated.log",
        ])

        session.sort(by: .size)
        #expect(session.sortDirection == .descending)
        #expect(session.filteredFiles.map(\.name) == [
            "a-folder", "z-folder", "large.txt", "undated.log", "small.txt",
        ])

        session.sort(by: .kind)
        #expect(session.sortDirection == .ascending)
        #expect(session.filteredFiles.map(\.name) == [
            "a-folder", "z-folder", "undated.log", "large.txt", "small.txt",
        ])
    }

    /// The visible list is cached rather than recomputed on every read, so the
    /// thing worth pinning is that each of its three inputs invalidates it —
    /// and that selection, which is not one of them, does not.
    @Test
    func sftpVisibleRowsFollowFilterAndSortButNotSelection() async {
        let notes = remoteFile(path: "/home/notes.txt", kind: .file, size: 10)
        let report = remoteFile(path: "/home/report.txt", kind: .file, size: 100)
        let archive = remoteFile(path: "/home/archive", kind: .directory)
        let client = SnapshotSFTPClient(responses: [.success([report, notes, archive])])
        let session = SFTPSessionModel(hostID: UUID(), initialPath: "/home", client: client)

        await session.reload(silently: true)
        #expect(session.visibleRows.map(\.file.name) == ["archive", "notes.txt", "report.txt"])
        #expect(session.visibleRows.map(\.sizeText) == ["--", "10 bytes", "100 bytes"])

        session.selection = [notes.id, report.id]
        #expect(session.visibleRows.map(\.file.name) == ["archive", "notes.txt", "report.txt"])
        #expect(session.selectedFiles == [notes, report])

        session.query = "report"
        #expect(session.visibleRows.map(\.file.name) == ["report.txt"])
        // The filter dropped a selected row, so the selection follows it out.
        #expect(session.selectedFiles == [report])

        session.sort(by: .size)
        #expect(session.sortDirection == .descending)
        #expect(session.visibleRows.map(\.file.name) == ["report.txt"])

        session.query = ""
        #expect(session.visibleRows.map(\.file.name) == ["archive", "report.txt", "notes.txt"])
    }

    @Test
    func sftpHiddenFilesAreExcludedByDefaultAndReconciledWithSelection() async {
        let hiddenFolder = remoteFile(path: "/home/.git", kind: .directory)
        let hiddenFile = remoteFile(path: "/home/.env", kind: .file)
        let visibleFile = remoteFile(path: "/home/readme.md", kind: .file)
        let client = SnapshotSFTPClient(
            responses: [.success([visibleFile, hiddenFile, hiddenFolder])]
        )
        let session = SFTPSessionModel(hostID: UUID(), initialPath: "/home", client: client)

        await session.reload(silently: true)
        #expect(session.visibleRows.map(\.file.name) == ["readme.md"])

        session.showsHiddenFiles = true
        #expect(session.visibleRows.map(\.file.name) == [".git", ".env", "readme.md"])

        session.selection = [hiddenFile.id]
        session.showsHiddenFiles = false
        #expect(session.visibleRows.map(\.file.name) == ["readme.md"])
        #expect(session.selection.isEmpty)
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
        let store = HostLibraryModel(
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
            modifiedAt: nil, permissions: 0o100754, ownerUID: 501, ownerGID: 20
        )
        #expect(file.permissionDescription == "-rwxr-xr--")
        #expect(file.permissionMode == 0o754)
        #expect(file.octalPermissionDescription == "0754")
        #expect(file.id == "/tmp/tool")
    }

    @Test
    func permissionDraftValidatesAndNormalizesOctalInput() {
        var draft = SFTPPermissionDraft(permissions: 0o1004755)
        #expect(draft.text == "4755")
        #expect(draft.mode == 0o4755)
        #expect(!draft.canSave)

        let rejectedInvalidDigits = draft.accept("4888")
        #expect(!rejectedInvalidDigits)
        #expect(draft.text == "4755")
        let acceptedEmptyDraft = draft.accept("")
        #expect(acceptedEmptyDraft)
        #expect(draft.parsedMode == nil)
        #expect(!draft.canSave)
        let acceptedShortMode = draft.accept("640")
        #expect(acceptedShortMode)
        #expect(draft.parsedMode == 0o640)
        draft.normalizeText()
        #expect(draft.text == "0640")
        #expect(draft.canSave)
    }

    @Test
    func permissionDraftSwitchesPreserveSpecialBits() {
        var draft = SFTPPermissionDraft(permissions: 0o4755)
        draft.set(0o020, enabled: true)
        #expect(draft.text == "4775")
        draft.set(0o100, enabled: false)
        #expect(draft.text == "4675")
        #expect(draft.mode & 0o7000 == 0o4000)
    }

    @Test
    func permissionUpdateWritesModeAndRefreshesDirectory() async {
        let file = remoteFile(path: "/home/tool", kind: .file)
        let client = PermissionSFTPClient(file: file)
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        let saved = await sftpSession.updatePermissions(for: file, to: 0o104755)

        #expect(saved)
        #expect(await client.lastPermissionUpdate == .init(path: "/home/tool", mode: 0o4755))
        #expect(sftpSession.files.first?.permissionMode == 0o4755)
        #expect(sftpSession.operationError == nil)
    }

    @Test
    func permissionUpdateFailureKeepsEditorOpenThroughFalseResult() async {
        let file = remoteFile(path: "/home/tool", kind: .file)
        let client = PermissionSFTPClient(file: file, rejectsUpdate: true)
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        let saved = await sftpSession.updatePermissions(for: file, to: 0o755)

        #expect(!saved)
        #expect(sftpSession.files.isEmpty)
        #expect(sftpSession.operationError == "Permission denied")
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
        let app = AppModel(hosts: HostLibraryModel())
        let window = WindowModel()
        app.registerWindow(window)

        app.shutdownForTermination()

        #expect(window.workspaces.isEmpty)
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
        #expect(sftpSession.displayedPath == "~")
    }

    @Test
    func configuredInitialPathStillResolvesHomeWithoutChangingNavigation() async throws {
        let client = ManifestSFTPClient(entries: [:], home: "/home/deploy")
        let session = SFTPSessionModel(hostID: UUID(), initialPath: "/home/deploy/project")

        try await session.resolveInitialPathIfNeeded(using: client)

        #expect(session.path == "/home/deploy/project")
        #expect(session.displayedPath == "~/project")
        #expect(await client.homeDirectoryRequestCount == 1)
    }

    @Test
    func configuredInitialPathFallsBackToAbsoluteWhenHomeIsUnavailable() async throws {
        let client = ManifestSFTPClient(entries: [:], rejectsHome: true)
        let session = SFTPSessionModel(hostID: UUID(), initialPath: "/srv/project")

        try await session.resolveInitialPathIfNeeded(using: client)

        #expect(session.homeResolution == .unavailable)
        #expect(session.displayedPath == "/srv/project")
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
    func directoryRefreshReconcilesRowsAndSelection() async {
        let retained = remoteFile(path: "/home/retained.txt", kind: .file)
        let removed = remoteFile(path: "/home/removed.txt", kind: .file)
        let client = SnapshotSFTPClient(
            responses: [.success([retained, removed]), .success([retained])]
        )
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpSession.reload(silently: true)
        sftpSession.selection = [retained.id, removed.id]
        await sftpSession.reload(silently: true)

        #expect(sftpSession.files == [retained])
        #expect(sftpSession.selection == [retained.id])
    }

    @Test
    func filteringPrunesSelectionThatIsNotRepresentedByTheTable() async {
        let visible = remoteFile(path: "/home/visible.txt", kind: .file)
        let hidden = remoteFile(path: "/home/hidden.log", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([visible, hidden])])
        let sftpSession = SFTPSessionModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpSession.reload(silently: true)
        sftpSession.selection = [hidden.id]
        sftpSession.query = "visible"

        #expect(sftpSession.filteredFiles == [visible])
        #expect(sftpSession.selection.isEmpty)
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
        let store = HostLibraryModel(hosts: [host])
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
        let store = HostLibraryModel(hosts: [host])
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

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
        let store = HostLibraryModel()
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
        let store = HostLibraryModel()
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
            store: HostLibraryModel(), clientFactory: { FakeSFTPTransferClient(gate: gate) },
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
        let store = HostLibraryModel()
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
        let store = HostLibraryModel()

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
        let store = HostLibraryModel()
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { sourceClient }
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) {
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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

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
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

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
    path: String, kind: RemoteFile.Kind, size: Int64 = 0, modifiedAt: Date? = nil
) -> RemoteFile {
    RemoteFile(
        path: path, name: (path as NSString).lastPathComponent, kind: kind,
        size: size, modifiedAt: modifiedAt, permissions: 0o644, ownerUID: 501, ownerGID: 20
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

private actor PermissionSFTPClient: SFTPClientProtocol {
    struct PermissionUpdate: Equatable, Sendable {
        var path: String
        var mode: UInt32
    }

    private var file: RemoteFile
    private let rejectsUpdate: Bool
    private(set) var lastPermissionUpdate: PermissionUpdate?

    init(file: RemoteFile, rejectsUpdate: Bool = false) {
        self.file = file
        self.rejectsUpdate = rejectsUpdate
    }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home" }
    func listDirectory(at path: String) async throws -> [RemoteFile] { [file] }
    func attributes(at path: String) async throws -> RemoteFile? { file }
    func setPermissions(at path: String, to permissions: UInt32) async throws {
        guard !rejectsUpdate else { throw SFTPError.operation("Permission denied") }
        let mode = permissions & 0o7777
        lastPermissionUpdate = PermissionUpdate(path: path, mode: mode)
        file.permissions = (file.permissions & ~UInt32(0o7777)) | mode
    }
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
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
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
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
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
    private let rejectsHome: Bool
    private(set) var createdDirectories: [String] = []
    private(set) var rejectedAttributeRequestCount = 0
    private(set) var homeDirectoryRequestCount = 0

    init(
        entries: [String: RemoteFile], rejectedAttributePrefix: String? = nil,
        home: String = "/Users/test", rejectsHome: Bool = false
    ) {
        self.entries = entries
        self.rejectedAttributePrefix = rejectedAttributePrefix
        self.home = home
        self.rejectsHome = rejectsHome
    }

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String {
        homeDirectoryRequestCount += 1
        if rejectsHome { throw SFTPError.operation("Home unavailable") }
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
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
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

private actor WritingSFTPClient: SFTPClientProtocol {
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async {}
    func homeDirectory() async throws -> String { "/home" }
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
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
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

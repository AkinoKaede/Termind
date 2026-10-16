import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing
import UniformTypeIdentifiers

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct SFTPFeatureTests {
    @Test
    func contextClickSelectsBeforeBuildingTargetsAndPreservesAnExistingMultiSelection() async {
        let first = remoteFile(path: "/home/a.txt", kind: .file)
        let second = remoteFile(path: "/home/b.txt", kind: .file)
        let third = remoteFile(path: "/home/c.txt", kind: .file)
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home",
            client: SnapshotSFTPClient(responses: [.success([first, second, third])]))
        await channel.reload(silently: true)

        #expect(channel.selectForContextMenu(first))
        #expect(channel.selection == [first.id])
        #expect(channel.menuTargets(for: first) == [first])

        channel.selection = [first.id, second.id]
        #expect(!channel.selectForContextMenu(second))
        #expect(channel.selection == [first.id, second.id])
        let targets = channel.menuTargets(for: second)
        #expect(targets == [first, second])

        #expect(channel.selectForContextMenu(third))
        #expect(channel.selection == [third.id])
        #expect(channel.menuTargets(for: third) == [third])
        #expect(targets == [first, second])
        #expect(!channel.selectForContextMenu(third))
    }

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
        let paused = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/paused", remotePath: "/paused",
            byteCount: 1_000, transferredBytes: 500, state: .paused
        )
        let finished = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/finished", remotePath: "/finished",
            byteCount: 1_000, transferredBytes: 1_000, state: .completed
        )
        let failed = SFTPTransfer(
            hostID: host.id, direction: .download,
            localPath: "/tmp/failed", remotePath: "/srv/failed",
            byteCount: 10, transferredBytes: 4, state: .failed("Network lost")
        )
        let store = HostLibraryModel(
            hosts: [host], sftpTransfers: [first, second, paused, finished, failed]
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
        let paused = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/paused", remotePath: "/paused",
            state: .paused
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
            sftpTransfers: [queued, running, paused, completed, cancelled, failed]
        )
        let coordinator = SFTPTransferCoordinator(store: store)

        coordinator.clearFinished()

        #expect(store.sftpTransfers.map(\.id) == [queued.id, running.id, paused.id])
    }

    @Test
    func removingOneFinishedTransferPreservesActiveWorkAndDownloadedFile() throws {
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("downloaded".utf8).write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let queued = SFTPTransfer(localPath: "/tmp/queued", remotePath: "/queued", state: .queued)
        let running = SFTPTransfer(localPath: "/tmp/running", remotePath: "/running", state: .running)
        let paused = SFTPTransfer(localPath: "/tmp/paused", remotePath: "/paused", state: .paused)
        let completed = SFTPTransfer(
            direction: .download, localPath: localURL.path, remotePath: "/completed", state: .completed)
        let cancelled = SFTPTransfer(localPath: "/tmp/cancelled", remotePath: "/cancelled", state: .cancelled)
        let failed = SFTPTransfer(localPath: "/tmp/failed", remotePath: "/failed", state: .failed("lost"))
        let store = HostLibraryModel(sftpTransfers: [queued, running, paused, completed, cancelled, failed])
        let coordinator = SFTPTransferCoordinator(store: store)

        for id in [queued.id, running.id, paused.id, UUID()] { coordinator.removeFinished(id) }
        #expect(store.sftpTransfers.count == 6)

        coordinator.removeFinished(completed.id)
        #expect(store.sftpTransfers.map(\.id) == [queued.id, running.id, paused.id, cancelled.id, failed.id])
        #expect(FileManager.default.fileExists(atPath: localURL.path))

        coordinator.removeFinished(cancelled.id)
        coordinator.removeFinished(failed.id)
        #expect(store.sftpTransfers.map(\.id) == [queued.id, running.id, paused.id])
    }

    @Test
    func remotePathsNormalizeWithoutEscapingRoot() {
        #expect(RemotePath.normalized(" /srv//releases/../current/ ") == "/srv/current")
        #expect(RemotePath.normalized("../../etc") == "/etc")
        #expect(RemotePath.parent(of: "/") == "/")
        #expect(RemotePath.parent(of: "/var/log") == "/var")
        #expect(RemotePath.join("/", "tmp") == "/tmp")
        #expect(
            RemotePath.components(of: "/var/log/nginx").map(\.path) == [
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
        let channel = SFTPChannelModel(hostID: UUID(), initialPath: "/home", client: client)

        await channel.reload(silently: true)
        #expect(
            channel.filteredFiles.map(\.name) == [
                "a-folder", "z-folder", "large.txt", "small.txt", "undated.log",
            ])

        channel.sort(by: .modified)
        #expect(channel.sortDirection == .descending)
        #expect(
            channel.filteredFiles.map(\.name) == [
                "a-folder", "z-folder", "large.txt", "small.txt", "undated.log",
            ])

        channel.sort(by: .size)
        #expect(channel.sortDirection == .descending)
        #expect(
            channel.filteredFiles.map(\.name) == [
                "a-folder", "z-folder", "large.txt", "undated.log", "small.txt",
            ])

        channel.sort(by: .kind)
        #expect(channel.sortDirection == .ascending)
        #expect(
            channel.filteredFiles.map(\.name) == [
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
        let channel = SFTPChannelModel(hostID: UUID(), initialPath: "/home", client: client)

        await channel.reload(silently: true)
        #expect(channel.visibleRows.map(\.file.name) == ["archive", "notes.txt", "report.txt"])
        #expect(channel.visibleRows.map(\.sizeText) == ["", "10 bytes", "100 bytes"])

        channel.selection = [notes.id, report.id]
        #expect(channel.visibleRows.map(\.file.name) == ["archive", "notes.txt", "report.txt"])
        #expect(channel.selectedFiles == [notes, report])

        channel.query = "report"
        #expect(channel.visibleRows.map(\.file.name) == ["report.txt"])
        // The filter dropped a selected row, so the selection follows it out.
        #expect(channel.selectedFiles == [report])

        channel.sort(by: .size)
        #expect(channel.sortDirection == .descending)
        #expect(channel.visibleRows.map(\.file.name) == ["report.txt"])

        channel.query = ""
        #expect(channel.visibleRows.map(\.file.name) == ["archive", "report.txt", "notes.txt"])
    }

    @Test
    func sftpHiddenFilesAreExcludedByDefaultAndReconciledWithSelection() async {
        let hiddenFolder = remoteFile(path: "/home/.git", kind: .directory)
        let hiddenFile = remoteFile(path: "/home/.env", kind: .file)
        let visibleFile = remoteFile(path: "/home/readme.md", kind: .file)
        let client = SnapshotSFTPClient(
            responses: [.success([visibleFile, hiddenFile, hiddenFolder])]
        )
        let channel = SFTPChannelModel(hostID: UUID(), initialPath: "/home", client: client)

        await channel.reload(silently: true)
        #expect(channel.visibleRows.map(\.file.name) == ["readme.md"])

        channel.showsHiddenFiles = true
        #expect(channel.visibleRows.map(\.file.name) == [".git", ".env", "readme.md"])

        channel.selection = [hiddenFile.id]
        channel.showsHiddenFiles = false
        #expect(channel.visibleRows.map(\.file.name) == ["readme.md"])
        #expect(channel.selection.isEmpty)
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
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        let saved = await sftpChannel.updatePermissions(for: file, to: 0o104755)

        #expect(saved)
        #expect(await client.lastPermissionUpdate == .init(path: "/home/tool", mode: 0o4755))
        #expect(sftpChannel.files.first?.permissionMode == 0o4755)
        #expect(sftpChannel.operationError == nil)
    }

    @Test
    func permissionUpdateFailureKeepsEditorOpenThroughFalseResult() async {
        let file = remoteFile(path: "/home/tool", kind: .file)
        let client = PermissionSFTPClient(file: file, rejectsUpdate: true)
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        let saved = await sftpChannel.updatePermissions(for: file, to: 0o755)

        #expect(!saved)
        #expect(sftpChannel.files.isEmpty)
        #expect(sftpChannel.operationError == "Permission denied")
    }

    @Test
    func hostDefaultsToRemoteHomeForSFTPChannel() {
        let host = Host(name: "Server", host: "server.example")
        #expect(host.sftpChannelInitialPath.isEmpty)
        let pane = Pane.sftpChannel(host: host)
        guard case .sftpChannel(let sftpChannel) = pane.content else {
            Issue.record("Expected SFTP channel pane")
            return
        }
        #expect(sftpChannel.path == "/")
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
        let sftpChannel = SFTPChannelModel(hostID: UUID(), initialPath: "")

        try await sftpChannel.resolveInitialPathIfNeeded(using: client)
        try await sftpChannel.resolveInitialPathIfNeeded(using: client)

        #expect(sftpChannel.path == "/home/deploy")
        #expect(sftpChannel.pathText == "/home/deploy")
        #expect(await client.homeDirectoryRequestCount == 1)
        #expect(sftpChannel.displayedPath == "~")
    }

    @Test
    func configuredInitialPathStillResolvesHomeWithoutChangingNavigation() async throws {
        let client = ManifestSFTPClient(entries: [:], home: "/home/deploy")
        let channel = SFTPChannelModel(hostID: UUID(), initialPath: "/home/deploy/project")

        try await channel.resolveInitialPathIfNeeded(using: client)

        #expect(channel.path == "/home/deploy/project")
        #expect(channel.displayedPath == "~/project")
        #expect(await client.homeDirectoryRequestCount == 1)
    }

    @Test
    func configuredInitialPathFallsBackToAbsoluteWhenHomeIsUnavailable() async throws {
        let client = ManifestSFTPClient(entries: [:], rejectsHome: true)
        let channel = SFTPChannelModel(hostID: UUID(), initialPath: "/srv/project")

        try await channel.resolveInitialPathIfNeeded(using: client)

        #expect(channel.homeResolution == .unavailable)
        #expect(channel.displayedPath == "/srv/project")
    }

    @Test
    func silentRefreshCommitsOnlySuccessfulSnapshots() async {
        let initial = remoteFile(path: "/home/old.txt", kind: .file)
        let updated = remoteFile(path: "/home/new.txt", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([initial]), .failure, .success([updated])])
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpChannel.reload(silently: true)
        #expect(sftpChannel.files == [initial])
        await sftpChannel.reload(silently: true)
        #expect(sftpChannel.files == [initial])
        #expect(sftpChannel.operationError == nil)
        await sftpChannel.reload(silently: true)
        #expect(sftpChannel.files == [updated])
    }

    @Test
    func directoryRefreshReconcilesRowsAndSelection() async {
        let retained = remoteFile(path: "/home/retained.txt", kind: .file)
        let removed = remoteFile(path: "/home/removed.txt", kind: .file)
        let client = SnapshotSFTPClient(
            responses: [.success([retained, removed]), .success([retained])]
        )
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpChannel.reload(silently: true)
        sftpChannel.selection = [retained.id, removed.id]
        await sftpChannel.reload(silently: true)

        #expect(sftpChannel.files == [retained])
        #expect(sftpChannel.selection == [retained.id])
    }

    @Test
    func filteringPrunesSelectionThatIsNotRepresentedByTheTable() async {
        let visible = remoteFile(path: "/home/visible.txt", kind: .file)
        let hidden = remoteFile(path: "/home/hidden.log", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([visible, hidden])])
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpChannel.reload(silently: true)
        sftpChannel.selection = [hidden.id]
        sftpChannel.query = "visible"

        #expect(sftpChannel.filteredFiles == [visible])
        #expect(sftpChannel.selection.isEmpty)
    }

    @Test
    func automaticRefreshRepeatsUntilDisconnect() async {
        let client = SnapshotSFTPClient(responses: [.success([])])
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration,
            automaticRefreshInterval: .milliseconds(10)
        )

        sftpChannel.startAutomaticRefresh()
        while await client.listRequestCount < 2 { await Task.yield() }
        sftpChannel.disconnect()
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
        let sftpChannel = SFTPChannelModel(
            hostID: host.id, initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        sftpChannel.bindStatus(to: store)

        await sftpChannel.reload()
        await sftpChannel.reload(silently: true)

        #expect(sftpChannel.status == .reconnecting)
        #expect(sftpChannel.reconnectState?.attempt == 1)
        #expect(sftpChannel.connectionJourney.mode == .reconnection)
        #expect(sftpChannel.connectionJourney.isPresented)
        #expect(sftpChannel.files == [existing])
        #expect(sftpChannel.path == "/home")
        sftpChannel.disconnect()
    }

    @Test
    func ordinarySFTPFailureDoesNotStartReconnect() async {
        let host = Host(name: "Files", host: "files.example")
        let client = SnapshotSFTPClient(responses: [.failure])
        let store = HostLibraryModel(hosts: [host])
        let sftpChannel = SFTPChannelModel(
            hostID: host.id, initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        sftpChannel.bindStatus(to: store)

        await sftpChannel.reload()

        #expect(sftpChannel.status == .connected)
        #expect(sftpChannel.reconnectState == nil)
        #expect(sftpChannel.operationError == "Refresh failed")
        sftpChannel.disconnect()
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
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await sftpChannel.prepareUpload([localFile])
        await sftpChannel.enqueuePending(policy: .replace, coordinator: coordinator)
        for _ in 0..<100 where sftpChannel.files.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(sftpChannel.files == [uploaded])
    }

    @Test
    func coordinatorHonorsGlobalAndPerHostLimits() async {
        let hostA = UUID()
        let hostB = UUID()
        let store = HostLibraryModel()
        let gate = SFTPTransferClientGate()
        let coordinator = SFTPTransferCoordinator(
            store: store, clientFactory: { FakeSFTPTransferClient(gate: gate) }, globalLimit: 3, perHostLimit: 2)
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

    @Test(arguments: [(15, 5), (100, 50)])
    func configuredLimitsBoundConcurrentFilesAcrossHosts(_ limits: (Int, Int)) async throws {
        let gate = SFTPTransferClientGate()
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { FakeSFTPTransferClient(gate: gate) },
            globalLimit: limits.0, perHostLimit: limits.1)
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        for index in 0..<4 {
            let hostID = UUID()
            for file in 0...limits.1 {
                coordinator.enqueue(
                    direction: .upload, batchID: UUID(), localURL: root.appending(path: "file-\(index)-\(file)"),
                    remotePath: "/file-\(file)", byteCount: 1, hostID: hostID,
                    configuration: makeTestConfiguration(hostID: hostID, host: "host-\(index)"),
                    scopedRoot: root, overwrite: true)
            }
        }
        await gate.waitForStarts(limits.0)
        #expect(await gate.maximumActive == limits.0)
        #expect(await gate.maximumActive(for: "host-0") == limits.1)
        for _ in 0..<500 {
            await gate.releaseAll()
            // Admission can still be pending between the last active task and its successor.
            if coordinator.sftpTransfers.allSatisfy({ $0.state.isFinished }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .completed })
        #expect(await gate.maximumActive == limits.0)
        for index in 0..<4 { #expect(await gate.maximumActive(for: "host-\(index)") <= limits.1) }
    }

    @Test
    func contextSerializesPrimaryChannelAndClosesItAfterOwnerRelease() async {
        let hostID = UUID()
        let store = HostLibraryModel()
        let gate = SFTPTransferClientGate()
        let client = PrimarySFTPTransferClient(gate: gate)
        let context = SFTPTransferContext(
            snapshot: SSHAdditionalConnectionSnapshot(
                configuration: makeTestConfiguration(hostID: hostID, host: "fixture.invalid")),
            channel: client, primaryRole: .ptyConnectionFallback)
        let coordinator = SFTPTransferCoordinator(
            store: store, globalLimit: 4, perHostLimit: 4
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())

        for index in 0..<2 {
            coordinator.enqueue(
                direction: .download, batchID: UUID(),
                localURL: root.appendingPathComponent("primary-\(index)"),
                remotePath: "/primary-\(index)", byteCount: 1,
                hostID: hostID, connection: .context(context),
                scopedRoot: root, overwrite: true
            )
        }

        await gate.waitForStarts(1)
        #expect(await gate.maximumActive == 1)
        await gate.releaseNext()
        await gate.waitForStarts(2)
        #expect(await gate.maximumActive == 1)
        await gate.releaseAll()

        while coordinator.activeCount > 0 { await Task.yield() }
        #expect(await client.connectCount == 0)
        #expect(await client.disconnectCount == 0)
        #expect(coordinator.sftpTransfers.allSatisfy { $0.state == .completed })
        await context.releaseOwner()
        #expect(await client.disconnectCount == 1)
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
    func decreasingLimitsLeavesActiveTransfersRunningAndConstrainsTheQueue() async {
        let gate = SFTPTransferClientGate()
        let coordinator = SFTPTransferCoordinator(
            store: HostLibraryModel(), clientFactory: { FakeSFTPTransferClient(gate: gate) },
            globalLimit: 3, perHostLimit: 3
        )
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        for index in 0..<4 {
            let hostID = UUID()
            coordinator.enqueue(
                direction: .download, batchID: UUID(),
                localURL: root.appendingPathComponent("decrease-limit-\(index)"),
                remotePath: "/decrease-limit-\(index)", byteCount: 1, hostID: hostID,
                configuration: makeTestConfiguration(hostID: hostID, host: "host-\(index)"),
                scopedRoot: root, overwrite: true
            )
        }
        await gate.waitForStarts(3)

        coordinator.updateLimits(global: 1, perHost: 1)

        #expect(coordinator.activeCount == 3)
        #expect(coordinator.sftpTransfers.filter { $0.state == .queued }.count == 1)
        await gate.releaseAll()
        await gate.waitForStarts(4)
        #expect(await gate.maximumActive == 3)
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
    func sshAndSFTPChannelStatusesAggregateForHostDots() {
        let hostID = UUID()
        let sshSessionID = UUID()
        let sftpChannelID = UUID()
        let store = HostLibraryModel()

        store.setConnectionStatus(.connected, connectionID: sshSessionID, hostID: hostID)
        store.setConnectionStatus(.connecting, connectionID: sftpChannelID, hostID: hostID)
        #expect(store.status(of: hostID) == .connected)

        store.setConnectionStatus(.disconnected, connectionID: sshSessionID, hostID: hostID)
        #expect(store.status(of: hostID) == .connecting)

        store.setConnectionStatus(.reconnecting, connectionID: sftpChannelID, hostID: hostID)
        #expect(store.status(of: hostID) == .reconnecting)

        store.setConnectionStatus(.connected, connectionID: sftpChannelID, hostID: hostID)
        #expect(store.status(of: hostID) == .connected)

        store.setConnectionStatus(.disconnected, connectionID: sftpChannelID, hostID: hostID)
        #expect(store.status(of: hostID) == .disconnected)
    }

    @Test
    func sftpChannelPublishesItsStatusToHostStore() {
        let hostID = UUID()
        let store = HostLibraryModel()
        let sftpChannel = SFTPChannelModel(
            hostID: hostID, initialPath: "/home",
            client: SnapshotSFTPClient(responses: [.success([])]),
            configuration: testConfiguration
        )

        sftpChannel.bindStatus(to: store)
        #expect(store.status(of: hostID) == .connected)

        sftpChannel.disconnect()
        #expect(store.status(of: hostID) == .disconnected)
    }

    @Test
    func multipleSelectionPreservesVisibleOrder() async {
        let first = remoteFile(path: "/home/a.txt", kind: .file)
        let second = remoteFile(path: "/home/b.txt", kind: .file)
        let client = SnapshotSFTPClient(responses: [.success([first, second])])
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )

        await sftpChannel.reload(silently: true)
        sftpChannel.selection = [second.id, first.id]

        #expect(sftpChannel.selectedFiles == [first, second])
    }

    @Test(arguments: [".bashrc", "README.md"])
    func finderDragRepresentationPreservesExactBasename(_ name: String) async {
        let client = WritingSFTPClient()
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/home", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }
        let file = remoteFile(path: "/home/\(name)", kind: .file)
        let provider = SFTPBrowserView.promisedFileProvider(
            for: file, sftpChannel: sftpChannel, coordinator: coordinator
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

    @Test(arguments: [false, true])
    func sameHostRemoteCopyRejectsItsSourceAndDescendants(_ intoDescendant: Bool) async throws {
        let hostID = UUID()
        let sourcePath = "/source/bundle"
        let bundle = remoteFile(path: sourcePath, kind: .directory)
        let source = TreeSFTPClient(listings: ["/source": [bundle], sourcePath: []])
        let destinationPath = intoDescendant ? "/source/bundle/nested" : "/source"
        let destination = ManifestSFTPClient(entries: [
            destinationPath: remoteFile(path: destinationPath, kind: .directory)
        ])
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { source }
        let payload = coordinator.registerRemoteCopySource(
            SFTPRemoteCopySource(
                hostID: hostID,
                configuration: makeTestConfiguration(hostID: hostID, host: "same-host"),
                files: [bundle]
            ))
        let channel = SFTPChannelModel(
            hostID: hostID, initialPath: destinationPath, client: destination,
            configuration: makeTestConfiguration(hostID: hostID, host: "same-host")
        )

        await channel.prepareRemoteCopy(payload, coordinator: coordinator)

        #expect(channel.operationError == String(localized: "A path cannot be copied into itself."))
        #expect(!channel.hasPendingBatch)
        #expect(coordinator.sftpTransfers.isEmpty)
        #expect(try await source.listDirectory(at: "/source").map(\.path) == [sourcePath])
    }

    @Test
    func remoteDownloadPlannerPreservesHierarchyAndEmptyDirectories() async throws {
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let empty = remoteFile(path: "/source/bundle/empty", kind: .directory)
        let readme = remoteFile(path: "/source/bundle/README.md", kind: .file, size: 4)
        let client = TreeSFTPClient(listings: [
            bundle.path: [empty, readme],
            empty.path: [],
        ])
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

        let batch = try await SFTPRemoteDownloadPlanner.prepare(
            [bundle], destination: destination, client: client
        )

        #expect(batch.transferCount == 1)
        #expect(batch.directoryCount == 2)
        #expect(batch.conflictCount == 0)
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth], [false, true])
    func downloadingAFileResolvesExistingFilesAndDirectories(
        policy: TransferConflictPolicy, existingIsDirectory: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "report.txt")
        if existingIsDirectory {
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        }
        let preserved = existingIsDirectory ? original.appending(path: "keep.txt") : original
        try Data("original".utf8).write(to: preserved)
        let client = WritingSFTPClient()
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/source", client: client, configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await channel.prepareDownload([remoteFile(path: "/source/report.txt", kind: .file)], to: root)
        #expect(channel.conflictCount == 1)
        await channel.enqueuePending(policy: policy, coordinator: coordinator)
        for _ in 0..<200 {
            guard coordinator.sftpTransfers.contains(where: { $0.state == .queued || $0.state == .running }) else {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(channel.operationError == nil)
        #expect(!channel.hasPendingBatch)
        if policy != .replace { #expect(try Data(contentsOf: preserved) == Data("original".utf8)) }
        if policy == .skip {
            #expect(coordinator.sftpTransfers.isEmpty)
        } else {
            let destination = policy == .keepBoth ? root.appending(path: "report.2.txt") : original
            #expect(coordinator.sftpTransfers.map(\.state) == [.completed])
            #expect(try Data(contentsOf: destination) == Data("termind".utf8))
        }
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth])
    func downloadingAConflictingDirectoryAppliesThePolicyToItsWholeSubtree(
        policy: TransferConflictPolicy
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "bundle")
        try Data("original".utf8).write(to: original)
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let nested = remoteFile(path: "/source/bundle/nested", kind: .directory)
        let file = remoteFile(path: "/source/bundle/nested/payload.txt", kind: .file)
        let sibling = remoteFile(path: "/source/bundle-other", kind: .directory)
        let client = TreeSFTPClient(listings: [bundle.path: [nested], nested.path: [file]])
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/source", client: client, configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await channel.prepareDownload([bundle, sibling], to: root)
        #expect(channel.conflictCount == 1)
        await channel.enqueuePending(policy: policy, coordinator: coordinator)

        #expect(channel.operationError == nil)
        #expect(!channel.hasPendingBatch)
        #expect(try root.appending(path: "bundle-other").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        if policy != .replace { #expect(try Data(contentsOf: original) == Data("original".utf8)) }
        if policy == .skip {
            #expect(coordinator.sftpTransfers.isEmpty)
        } else {
            let directory = policy == .keepBoth ? root.appending(path: "bundle.2") : original
            let destination = directory.appending(path: "nested/payload.txt")
            #expect(coordinator.sftpTransfers.map(\.localPath) == [destination.path])
            #expect(coordinator.sftpTransfers.map(\.remotePath) == [file.path])
            #expect(coordinator.sftpTransfers.map(\.direction) == [.download])
            #expect(
                try directory.appending(path: "nested").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        }
    }

    @Test
    func downloadingOnlyEmptyDirectoriesCreatesThemUnlessTheBatchWasCancelled() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let empty = remoteFile(path: "/source/bundle/empty", kind: .directory)
        let client = TreeSFTPClient(listings: [bundle.path: [empty]])
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/source", client: client, configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await channel.prepareDownload([bundle], to: root)
        #expect(channel.hasPendingBatch)
        channel.cancelPendingBatch()
        await channel.enqueuePending(policy: .skip, coordinator: coordinator)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        await channel.prepareDownload([bundle], to: root)
        await channel.enqueuePending(policy: .skip, coordinator: coordinator)

        #expect(channel.operationError == nil)
        #expect(!channel.hasPendingBatch)
        #expect(coordinator.sftpTransfers.isEmpty)
        #expect(try root.appending(path: "bundle/empty").resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth], [RemoteFile.Kind.file, .directory])
    func remoteCopyResolvesExistingFilesAndDirectories(
        policy: TransferConflictPolicy, kind: RemoteFile.Kind
    ) async throws {
        let sourceHostID = UUID()
        let targetHostID = UUID()
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let readme = remoteFile(path: "/source/bundle/README.md", kind: .file, size: 4)
        let sourceClient = TreeSFTPClient(listings: [bundle.path: [readme]])
        let targetClient = ManifestSFTPClient(entries: [
            "/incoming/bundle/README.md": remoteFile(
                path: "/incoming/bundle/README.md", kind: kind, size: 3
            )
        ])
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { sourceClient }
        let payload = coordinator.registerRemoteCopySource(
            SFTPRemoteCopySource(
                hostID: sourceHostID,
                configuration: makeTestConfiguration(hostID: sourceHostID, host: "source"),
                files: [bundle]
            ))
        let target = SFTPChannelModel(
            hostID: targetHostID, initialPath: "/incoming", client: targetClient,
            configuration: makeTestConfiguration(hostID: targetHostID, host: "target")
        )

        await target.prepareRemoteCopy(payload, coordinator: coordinator)

        #expect(target.pendingRemoteCopyBatch?.directoryCount == 1)
        #expect(target.pendingRemoteCopyBatch?.transferCount == 1)
        #expect(target.conflictCount == 1)
        await target.enqueuePendingRemoteCopy(policy: policy, coordinator: coordinator)
        #expect(!target.hasPendingBatch)
        #expect(target.operationError == nil)
        let name = policy == .keepBoth ? "README.2.md" : "README.md"
        #expect(coordinator.sftpTransfers.map(\.remotePath) == (policy == .skip ? [] : ["/incoming/bundle/\(name)"]))
        #expect(coordinator.sftpTransfers.allSatisfy { $0.direction == .copy && $0.localPath == readme.path })
        let existing = try await targetClient.attributes(at: "/incoming/bundle/README.md")
        #expect(existing?.kind == (policy == .replace && kind == .directory ? nil : kind))
    }

    @Test(arguments: [TransferConflictPolicy.skip, .replace, .keepBoth])
    func remoteCopyDirectoryConflictsApplyToTheWholeSubtree(policy: TransferConflictPolicy) async throws {
        let bundle = remoteFile(path: "/source/bundle", kind: .directory)
        let nested = remoteFile(path: "/source/bundle/nested", kind: .directory)
        let file = remoteFile(path: "/source/bundle/nested/payload.txt", kind: .file)
        let sibling = remoteFile(path: "/source/bundle-other", kind: .directory)
        let source = TreeSFTPClient(listings: [bundle.path: [nested], nested.path: [file]])
        let destination = ManifestSFTPClient(
            entries: ["/incoming/bundle": remoteFile(path: "/incoming/bundle", kind: .file)],
            rejectedAttributePrefix: policy == .replace ? nil : "/incoming/bundle/"
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { source }
        let payload = coordinator.registerRemoteCopySource(
            SFTPRemoteCopySource(hostID: UUID(), configuration: testConfiguration, files: [bundle, sibling]))
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/incoming", client: destination, configuration: testConfiguration
        )

        await channel.prepareRemoteCopy(payload, coordinator: coordinator)
        #expect(channel.conflictCount == 1)
        await channel.enqueuePendingRemoteCopy(policy: policy, coordinator: coordinator)

        #expect(channel.operationError == nil)
        #expect(!channel.hasPendingBatch)
        #expect(await destination.rejectedAttributeRequestCount == 0)
        #expect(try await destination.attributes(at: "/incoming/bundle-other")?.isDirectory == true)
        let directory = policy == .keepBoth ? "/incoming/bundle.2" : "/incoming/bundle"
        #expect(
            coordinator.sftpTransfers.map(\.remotePath) == (policy == .skip ? [] : [directory + "/nested/payload.txt"]))
        if policy != .replace { #expect(try await destination.attributes(at: "/incoming/bundle")?.kind == .file) }
    }

    @Test
    func remoteCopyOfEmptyDirectoriesRefreshesTheBrowserAndHonorsPendingCancellation() async throws {
        let empty = remoteFile(path: "/source/empty", kind: .directory)
        let source = TreeSFTPClient(listings: [:])
        let destination = ManifestSFTPClient(entries: [:])
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { source }
        let payload = coordinator.registerRemoteCopySource(
            SFTPRemoteCopySource(hostID: UUID(), configuration: testConfiguration, files: [empty]))
        let channel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/incoming", client: destination, configuration: testConfiguration
        )

        await channel.prepareRemoteCopy(payload, coordinator: coordinator)
        channel.cancelPendingBatch()
        await channel.enqueuePendingRemoteCopy(policy: .replace, coordinator: coordinator)
        #expect(await destination.createdDirectories.isEmpty)

        await channel.prepareRemoteCopy(payload, coordinator: coordinator)
        await channel.enqueuePendingRemoteCopy(policy: .replace, coordinator: coordinator)
        for _ in 0..<200 {
            if !channel.files.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(channel.files.map(\.path) == ["/incoming/empty"])
        #expect(channel.operationError == nil)
        #expect(!channel.hasPendingBatch)
        #expect(coordinator.sftpTransfers.isEmpty)
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
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )

        await sftpChannel.prepareUpload([localFile])

        #expect(sftpChannel.pendingUploadBatch?.conflictCount == 1)
        #expect(sftpChannel.pendingUploadBatch?.transferCount == 1)
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
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await sftpChannel.prepareUpload([upload])
        #expect(sftpChannel.pendingUploadBatch?.conflictCount == 1)
        #expect(sftpChannel.operationError == nil)

        await sftpChannel.enqueuePending(policy: .skip, coordinator: coordinator)

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
        let sftpChannel = SFTPChannelModel(
            hostID: UUID(), initialPath: "/incoming", client: client,
            configuration: testConfiguration
        )
        let coordinator = SFTPTransferCoordinator(store: HostLibraryModel()) { client }

        await sftpChannel.prepareUpload([upload])
        var uploadedPaths: [[String]] = []
        await sftpChannel.enqueuePending(
            policy: .keepBoth, coordinator: coordinator,
            uploadedPaths: { uploadedPaths.append($0) })
        for _ in 0..<200 {
            if !uploadedPaths.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(uploadedPaths == [["/incoming/bundle.2"]])

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

private nonisolated func remoteFile(
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
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var maximumActive: Int { maximum }
    func maximumActive(for host: String) -> Int { maximumByHost[host, default: 0] }

    func enter(host: String) async {
        active += 1
        activeByHost[host, default: 0] += 1
        starts += 1
        let ready = startWaiters.filter { starts >= $0.0 }
        startWaiters.removeAll { starts >= $0.0 }
        for (_, waiter) in ready { waiter.resume() }
        maximum = max(maximum, active)
        maximumByHost[host] = max(maximumByHost[host, default: 0], activeByHost[host, default: 0])
        await withCheckedContinuation { continuations.append($0) }
        active -= 1
        activeByHost[host, default: 1] -= 1
    }

    func waitForStarts(_ count: Int) async {
        guard starts < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
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

private actor PrimarySFTPTransferClient: SFTPClientProtocol {
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
    ) async throws { await gate.enter(host: "primary") }
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws { await gate.enter(host: "primary") }
}

private actor ManifestSFTPClient: SFTPClientProtocol {
    private var entries: [String: RemoteFile]
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
    func listDirectory(at path: String) async throws -> [RemoteFile] {
        entries.values.filter { ($0.path as NSString).deletingLastPathComponent == path }
    }
    func attributes(at path: String) async throws -> RemoteFile? {
        if let rejectedAttributePrefix, path.hasPrefix(rejectedAttributePrefix) {
            rejectedAttributeRequestCount += 1
            throw SFTPError.operation("Unexpected descendant stat: \(path)")
        }
        return entries[path]
    }
    func setPermissions(at path: String, to permissions: UInt32) async throws {}
    func createDirectory(at path: String) async throws {
        createdDirectories.append(path)
        entries[path] = remoteFile(path: path, kind: .directory)
    }
    func rename(from source: String, to destination: String, overwrite: Bool) async throws {}
    func removeFile(at path: String) async throws { entries[path] = nil }
    func removeDirectory(at path: String) async throws { entries[path] = nil }
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
        on destination: any SFTPChannelProtocol,
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

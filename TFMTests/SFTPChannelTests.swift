import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct SFTPChannelTests {
    @Test
    func workspaceSubtitleTracksSFTPPathEvenWhenRenamed() async throws {
        let host = Host(name: "Files", host: "files.example")
        let store = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/srv")
        let window = WindowModel(workspaces: [workspace])
        let channel = try #require(workspace.focusedPane.sftpChannel)
        try await channel.resolveInitialPathIfNeeded(using: LifecycleSFTPClient())

        #expect(workspace.subtitle(in: store) == "/srv")
        window.rename(workspace.id, to: "Logs")
        #expect(workspace.title(in: store) == "Logs")
        #expect(workspace.subtitle(in: store) == "/srv")

        channel.navigate(to: "/var/log")
        #expect(workspace.subtitle(in: store) == "/var/log")
    }

    @Test
    func workspaceWaitsForHomeThenUsesTilde() async throws {
        let host = Host(name: "Files", host: "files.example")
        let store = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sftpChannel(host: host, initialPath: "/home/test/project")
        let channel = try #require(workspace.focusedPane.sftpChannel)

        #expect(workspace.subtitle(in: store) == nil)
        try await channel.resolveInitialPathIfNeeded(using: LifecycleSFTPClient())
        #expect(workspace.subtitle(in: store) == "~/project")
    }

    @Test
    func findFocusRequestsRepeatWithoutClearingTheQuery() throws {
        let host = Host(name: "Files", host: "files.example")
        let window = WindowModel(workspaces: [Workspace.sftpChannel(host: host)])
        let channel = try #require(window.focusedSFTPChannel)
        channel.query = "release"

        window.focusToolbarFind()
        window.focusToolbarFind()

        #expect(window.findFocusRequest == 2)
        #expect(channel.query == "release")
    }

    @Test
    func navigationAndHistoryBelongToTheChannel() {
        let sftpChannel = SFTPChannelModel(hostID: UUID(), initialPath: "/var/log/")

        #expect(sftpChannel.path == "/var/log")
        sftpChannel.navigate(to: "/etc")
        sftpChannel.navigate(to: "/srv")
        sftpChannel.goBack()
        #expect(sftpChannel.path == "/etc")
        #expect(sftpChannel.canGoForward)

        sftpChannel.goForward()
        #expect(sftpChannel.path == "/srv")
    }

    @Test
    func movingAPaneKeepsTheSameSFTPChannelAndConnection() async {
        let host = Host(name: "Files", host: "files.example")
        let client = LifecycleSFTPClient()
        let sftpChannel = SFTPChannelModel(
            hostID: host.id, initialPath: "/", client: client
        )
        let source = Workspace(pane: Pane(.sftpChannel(sftpChannel)))
        let target = Workspace.sshSession(host: host)
        let pane = source.focusedPane
        sftpChannel.navigate(to: "/srv/releases")
        let window = WindowModel(workspaces: [source, target])

        window.merge(
            source.id, into: target.id, beside: target.focusedPane.id,
            axis: .horizontal, side: .after
        )

        #expect(window.pane(pane.id) === pane)
        guard case .sftpChannel(let moved)? = window.pane(pane.id)?.content else {
            Issue.record("Moved browser was lost")
            return
        }
        #expect(moved === sftpChannel)
        #expect(moved.path == "/srv/releases")
        await Task.yield()
        #expect(await client.disconnectCount == 0)
    }

    @Test
    func duplicateCreatesAnIndependentDefaultBrowser() {
        let host = Host(name: "Files", host: "files.example")
        let original = Pane.sftpChannel(host: host)
        guard case .sftpChannel(let sftpChannel) = original.content else {
            Issue.record("Expected an SFTP channel pane")
            return
        }
        sftpChannel.navigate(to: "/srv/releases")

        guard let copy = original.copy(), case .sftpChannel(let duplicate) = copy.content else {
            Issue.record("Expected a duplicated SFTP channel pane")
            return
        }

        #expect(duplicate !== sftpChannel)
        #expect(duplicate.hostID == sftpChannel.hostID)
        #expect(duplicate.path == "/")
        duplicate.navigate(to: "/tmp")
        #expect(sftpChannel.path == "/srv/releases")
    }

    @Test
    func closingBrowserDoesNotRemoveGlobalTransfers() {
        let host = Host(name: "Files", host: "files.example")
        let sftpTransfer = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/archive.zip",
            remotePath: "/srv/archive.zip"
        )
        let store = HostLibraryModel(hosts: [host], sftpTransfers: [sftpTransfer])
        let workspace = Workspace.sftpChannel(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.closePane(workspace.focusedPane.id)

        #expect(window.workspaces.isEmpty)
        #expect(store.sftpTransfers == [sftpTransfer])
    }

    @Test
    func closingBrowserDisconnectsItsBrowsingConnection() async {
        let host = Host(name: "Files", host: "files.example")
        let client = LifecycleSFTPClient()
        let sftpChannel = SFTPChannelModel(
            hostID: host.id, initialPath: "/", client: client
        )
        let workspace = Workspace(pane: Pane(.sftpChannel(sftpChannel)))
        let window = WindowModel(workspaces: [workspace])

        window.closePane(workspace.focusedPane.id)
        while await client.disconnectCount == 0 { await Task.yield() }

        #expect(await client.disconnectCount == 1)
        #expect(sftpChannel.status == .disconnected)
    }
}

private actor LifecycleSFTPClient: SFTPClientProtocol {
    private(set) var disconnectCount = 0

    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws {}
    func disconnect() async { disconnectCount += 1 }
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

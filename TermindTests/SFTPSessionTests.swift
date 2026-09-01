import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct SFTPSessionTests {
    @Test
    func workspaceSubtitleTracksSFTPPathEvenWhenRenamed() async throws {
        let host = Host(name: "Files", host: "files.example")
        let store = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sftpSession(host: host, initialPath: "/srv")
        let window = WindowModel(workspaces: [workspace])
        let session = try #require(workspace.focusedPane.sftpSession)
        try await session.resolveInitialPathIfNeeded(using: LifecycleSFTPClient())

        #expect(workspace.subtitle(in: store) == "/srv")
        window.rename(workspace.id, to: "Logs")
        #expect(workspace.title(in: store) == "Logs")
        #expect(workspace.subtitle(in: store) == "/srv")

        session.navigate(to: "/var/log")
        #expect(workspace.subtitle(in: store) == "/var/log")
    }

    @Test
    func workspaceWaitsForHomeThenUsesTilde() async throws {
        let host = Host(name: "Files", host: "files.example")
        let store = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sftpSession(host: host, initialPath: "/home/test/project")
        let session = try #require(workspace.focusedPane.sftpSession)

        #expect(workspace.subtitle(in: store) == nil)
        try await session.resolveInitialPathIfNeeded(using: LifecycleSFTPClient())
        #expect(workspace.subtitle(in: store) == "~/project")
    }

    @Test
    func findFocusRequestsRepeatWithoutClearingTheQuery() throws {
        let host = Host(name: "Files", host: "files.example")
        let window = WindowModel(workspaces: [Workspace.sftpSession(host: host)])
        let session = try #require(window.focusedSFTPSession)
        session.query = "release"

        window.focusToolbarFind()
        window.focusToolbarFind()

        #expect(window.findFocusRequest == 2)
        #expect(session.query == "release")
    }

    @Test
    func navigationAndHistoryBelongToTheSession() {
        let sftpSession = SFTPSessionModel(hostID: UUID(), initialPath: "/var/log/")

        #expect(sftpSession.path == "/var/log")
        sftpSession.navigate(to: "/etc")
        sftpSession.navigate(to: "/srv")
        sftpSession.goBack()
        #expect(sftpSession.path == "/etc")
        #expect(sftpSession.canGoForward)

        sftpSession.goForward()
        #expect(sftpSession.path == "/srv")
    }

    @Test
    func movingAPaneKeepsTheSameSFTPSessionAndConnection() async {
        let host = Host(name: "Files", host: "files.example")
        let client = LifecycleSFTPClient()
        let sftpSession = SFTPSessionModel(
            hostID: host.id, initialPath: "/", client: client
        )
        let source = Workspace(pane: Pane(.sftpSession(sftpSession)))
        let target = Workspace.sshSession(host: host)
        let pane = source.focusedPane
        sftpSession.navigate(to: "/srv/releases")
        let window = WindowModel(workspaces: [source, target])

        window.merge(
            source.id, into: target.id, beside: target.focusedPane.id,
            axis: .horizontal, side: .after
        )

        #expect(window.pane(pane.id) === pane)
        guard case .sftpSession(let moved)? = window.pane(pane.id)?.content else {
            Issue.record("Moved browser was lost")
            return
        }
        #expect(moved === sftpSession)
        #expect(moved.path == "/srv/releases")
        await Task.yield()
        #expect(await client.disconnectCount == 0)
    }

    @Test
    func duplicateCreatesAnIndependentDefaultBrowser() {
        let host = Host(name: "Files", host: "files.example")
        let original = Pane.sftpSession(host: host)
        guard case .sftpSession(let sftpSession) = original.content else {
            Issue.record("Expected an SFTP session pane")
            return
        }
        sftpSession.navigate(to: "/srv/releases")

        guard let copy = original.copy(), case .sftpSession(let duplicate) = copy.content else {
            Issue.record("Expected a duplicated SFTP session pane")
            return
        }

        #expect(duplicate !== sftpSession)
        #expect(duplicate.hostID == sftpSession.hostID)
        #expect(duplicate.path == "/")
        duplicate.navigate(to: "/tmp")
        #expect(sftpSession.path == "/srv/releases")
    }

    @Test
    func closingBrowserDoesNotRemoveGlobalTransfers() {
        let host = Host(name: "Files", host: "files.example")
        let sftpTransfer = SFTPTransfer(
            hostID: host.id, localPath: "/tmp/archive.zip",
            remotePath: "/srv/archive.zip"
        )
        let store = HostLibraryModel(hosts: [host], sftpTransfers: [sftpTransfer])
        let workspace = Workspace.sftpSession(host: host)
        let window = WindowModel(workspaces: [workspace])

        window.closePane(workspace.focusedPane.id)

        #expect(window.workspaces.isEmpty)
        #expect(store.sftpTransfers == [sftpTransfer])
    }

    @Test
    func closingBrowserDisconnectsItsBrowsingConnection() async {
        let host = Host(name: "Files", host: "files.example")
        let client = LifecycleSFTPClient()
        let sftpSession = SFTPSessionModel(
            hostID: host.id, initialPath: "/", client: client
        )
        let workspace = Workspace(pane: Pane(.sftpSession(sftpSession)))
        let window = WindowModel(workspaces: [workspace])

        window.closePane(workspace.focusedPane.id)
        while await client.disconnectCount == 0 { await Task.yield() }

        #expect(await client.disconnectCount == 1)
        #expect(sftpSession.status == .disconnected)
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

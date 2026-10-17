import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct WorkspaceBackgroundCloseTests {
    @Test(arguments: ["workspace", "pane", "others", "all"])
    func explicitCloseDoesNotWaitForRemoteCleanup(action: String) async throws {
        let host = Host(name: "Host", host: "example.invalid")
        let hosts = HostLibraryModel(hosts: [host])
        let workspaces = (0..<3).map { _ in Workspace.sshSession(host: host) }
        if action == "pane" {
            workspaces[0].splitFocusedPane(axis: .horizontal, with: .sshSession(host: host))
        }
        for pane in workspaces.flatMap(\.panes) {
            let session = try #require(pane.sshSession)
            session.sessionPersistence.attachment = .init(
                backend: .tmux, session: .init(id: pane.id.uuidString, name: "Shell", identity: Data([1])),
                hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: UUID())
        }
        var attempts = 0
        let closer = RemoteSessionCloseCoordinator { _ in
            attempts += 1
            try await Task.sleep(for: .seconds(60))
        }
        let model = WindowModel(workspaces: workspaces)
        model.hostStore = hosts
        model.persistentSessionCloser = closer
        var saved: [ClosedWorkspaceRecord] = []
        model.rememberClosedWorkspace = { saved.append(.init($0, hosts: hosts)) }
        defer {
            closer.cancelAll()
            model.closeForWindow()
        }
        switch action {
        case "workspace":
            model.close(workspaces[0].id)
            #expect(model.workspaces.count == 2)
        case "pane":
            model.closePane(workspaces[0].focusedPaneID)
            #expect(model.workspaces.count == 3)
            #expect(workspaces[0].panes.count == 1)
        case "others":
            model.closeOthers(than: workspaces[0].id)
            #expect(model.workspaces.map(\.id) == [workspaces[0].id])
        default:
            model.closeAll()
            #expect(model.workspaces.isEmpty)
        }
        #expect(attempts == 0)
        #expect(closer.isClosing)
        #expect(!saved.isEmpty)
        #expect(saved.flatMap { $0.remoteSessions ?? [] }.allSatisfy { $0 == nil })
        closer.cancelAll()
        await closer.waitUntilIdle()
    }

    @Test func passiveCloseDoesNotQueueRemoteTermination() throws {
        let host = Host(name: "Host", host: "example.invalid")
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "1", name: "Shell", identity: Data([1])),
            hostID: host.id, endpoint: "example.invalid:22", username: "user", ownershipToken: UUID())
        session.sessionPersistence.attachment = reference
        let model = WindowModel(workspaces: [workspace])
        model.hostStore = HostLibraryModel(hosts: [host])
        let closer = RemoteSessionCloseCoordinator { _ in Issue.record("Quit must not end remote sessions") }
        model.persistentSessionCloser = closer
        model.closeAll(intent: .applicationTermination)
        #expect(model.workspaces.isEmpty)
        #expect(!closer.isClosing)
        #expect(session.restorableRemoteSession == reference)
    }
}

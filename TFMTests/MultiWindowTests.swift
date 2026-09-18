import AppKit
import TermindApplication
import TermindDomain
import TermindInfrastructure
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct MultiWindowTests {
    @Test
    func moveWaitsForDestinationAndPreservesWorkspaceIdentityAndRouting() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let workspace = Workspace.sshSession(host: host)
        let second = Pane.sshSession(host: host)
        workspace.layout = .split(
            SplitNode.Branch(axis: .horizontal, fraction: 0.37, first: workspace.layout, second: .leaf(second)))
        workspace.focusedPaneID = second.id
        workspace.customTitle = "Two terminals"
        workspace.broadcastsInput = true
        let sessions = workspace.panes.compactMap(\.sshSession)
        for session in sessions { session.status = .connected }
        let source = WindowModel(workspaces: [workspace])
        let target = WindowModel()
        let sourceNative = nativeWindow()
        let targetNative = nativeWindow()
        defer {
            sourceNative.close()
            targetNative.close()
        }
        app.mainWindows.register(sourceNative, model: source, requestID: nil)
        var created: [UUID] = []
        app.mainWindows.createScene = { created.append($0) }

        let request = try #require(app.mainWindows.moveWorkspace(workspace.id, from: source))
        #expect(source.workspaces.first === workspace)
        #expect(target.workspaces.isEmpty)
        #expect(app.mainWindows.moveWorkspace(workspace.id, from: source) == request)
        #expect(Set(created) == [request])

        app.mainWindows.register(targetNative, model: target, requestID: request)
        #expect(source.workspaces.isEmpty)
        #expect(!source.canReopen)
        #expect(!source.isClosed)
        #expect(source.vaultDestination == .welcome)
        #expect(target.selectedWorkspace === workspace)
        #expect(workspace.lifecycleRouter === target)
        #expect(workspace.focusedPaneID == second.id)
        #expect(workspace.customTitle == "Two terminals")
        #expect(workspace.broadcastsInput)
        for (actual, expected) in zip(workspace.panes.compactMap(\.sshSession), sessions) {
            #expect(actual === expected)
            #expect(actual.status == .connected)
        }
        if case .split(let branch) = workspace.layout {
            #expect(branch.fraction == 0.37)
        } else {
            Issue.record("Split layout was lost")
        }

        app.mainWindows.register(targetNative, model: target, requestID: request)
        #expect(target.workspaces.count == 1)
        sourceNative.close()
        #expect(sessions.allSatisfy { $0.status == .connected })
        target.workspace(workspace, closePaneAfterSSHSessionExit: second.id)
        #expect(workspace.panes.count == 1)
        #expect(source.workspaces.isEmpty)
        targetNative.close()
        #expect(sessions.allSatisfy { $0.status == .disconnected })
    }

    @Test
    func concurrentWelcomeAndMetricsRequestsCannotConsumeEachOthersDestination() throws {
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let welcomeRequest = try #require(app.mainWindows.newWindow())
        let metricsRequest = try #require(app.mainWindows.newWindow(showsMetrics: true))
        let welcome = WindowModel()
        let metrics = WindowModel()
        let first = nativeWindow()
        let second = nativeWindow()
        defer {
            first.close()
            second.close()
        }
        app.mainWindows.register(second, model: metrics, requestID: metricsRequest)
        app.mainWindows.register(first, model: welcome, requestID: welcomeRequest)
        #expect(welcome.selectedDestination == .vault)
        #expect(metrics.selectedDestination == .metrics)
        #expect(first.tabbingMode == .disallowed)
        #expect(second.tabbingMode == .disallowed)
        let chat = welcome.assistantLibrary.createConversation()
        #expect(metrics.assistantLibrary.conversation(id: chat.id) === chat)
        welcome.assistantQuery = "local search"
        welcome.isQuickOpenPresented = true
        #expect(metrics.assistantQuery.isEmpty)
        #expect(!metrics.isQuickOpenPresented)
    }

    @Test
    func closingTheSourceCancelsAnUnclaimedMoveAndCannotResurrectSessions() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        app.mainWindows.createScene = { _ in }
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        session.status = .connected
        let source = WindowModel(workspaces: [workspace])
        let target = WindowModel()
        let first = nativeWindow()
        let second = nativeWindow()
        defer {
            first.close()
            second.close()
        }
        app.mainWindows.register(first, model: source, requestID: nil)
        let request = try #require(app.mainWindows.moveWorkspace(workspace.id, from: source))
        first.close()
        #expect(source.isClosed)
        #expect(session.status == .disconnected)
        app.mainWindows.register(second, model: target, requestID: request)
        #expect(target.workspaces.isEmpty)
        #expect(!source.canReopen)
        source.closeForWindow()
        session.status = .connecting
        let phase = session.connectionJourney.phase
        session.connectIfNeeded(using: app.hostLibrary)
        #expect(session.connectionJourney.phase == phase)
    }

    @Test
    func missingFactoryNeverRemovesWorkspaceAndStaleRestorationStartsEmpty() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let source = WindowModel(workspaces: [workspace])
        let app = AppModel(hosts: HostLibraryModel())
        #expect(app.mainWindows.moveWorkspace(workspace.id, from: source) == nil)
        #expect(source.selectedWorkspace === workspace)
        let restored = WindowModel()
        let native = nativeWindow()
        defer { native.close() }
        app.mainWindows.register(native, model: restored, requestID: UUID())
        #expect(restored.workspaces.isEmpty)
        #expect(restored.selectedDestination == .vault)
        source.closeForWindow()
    }

    @Test
    func paywallStaysWithOneWindowAndClosesWithItsOwner() {
        let app = AppModel(hosts: HostLibraryModel())
        let first = nativeWindow()
        let second = nativeWindow()
        let firstModel = WindowModel()
        let secondModel = WindowModel()
        defer {
            first.close()
            second.close()
        }
        app.mainWindows.register(first, model: firstModel, requestID: nil)
        app.mainWindows.register(second, model: secondModel, requestID: nil)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: first)
        app.proAccess.isPaywallPresented = true
        app.mainWindows.synchronizePaywall()
        #expect(app.mainWindows.paywallOwnerID == ObjectIdentifier(firstModel))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: second)
        #expect(app.mainWindows.paywallOwnerID == ObjectIdentifier(firstModel))
        first.close()
        #expect(!app.proAccess.isPaywallPresented)
        #expect(app.mainWindows.paywallOwnerID == nil)
        #expect(!secondModel.isClosed)
    }

    @Test
    func closingDestinationDoesNotCloseAnotherWindowsConnection() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let firstWorkspace = Workspace.sshSession(host: host)
        let secondWorkspace = Workspace.sshSession(host: host)
        let firstSession = try #require(firstWorkspace.focusedPane.sshSession)
        let secondSession = try #require(secondWorkspace.focusedPane.sshSession)
        firstSession.status = .connected
        secondSession.status = .connected
        let firstModel = WindowModel(workspaces: [firstWorkspace])
        let secondModel = WindowModel(workspaces: [secondWorkspace])
        let first = nativeWindow()
        let second = nativeWindow()
        defer {
            first.close()
            second.close()
        }
        app.mainWindows.register(first, model: firstModel, requestID: nil)
        app.mainWindows.register(second, model: secondModel, requestID: nil)
        first.close()
        #expect(firstSession.status == .disconnected)
        #expect(secondSession.status == .connected)
        #expect(secondModel.selectedWorkspace === secondWorkspace)
    }

    @Test
    func remountingMigratedSSHAndSFTPPanesPreservesAuthenticationPrompts() async throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let sshWorkspace = Workspace.sshSession(host: host)
        let sftpWorkspace = Workspace.sftpSession(host: host, initialPath: "/srv")
        let ssh = try #require(sshWorkspace.focusedPane.sshSession)
        let sftp = try #require(sftpWorkspace.focusedPane.sftpSession)
        ssh.connectIfNeeded(using: app.hostLibrary)
        sftp.connectIfNeeded(using: app.transfers)
        let sshPrompt = try #require(ssh.pendingAuthentication)
        for _ in 0..<100 where sftp.pendingAuthentication == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sftpPrompt = try #require(sftp.pendingAuthentication)
        let source = WindowModel(workspaces: [sshWorkspace, sftpWorkspace])
        let destination = WindowModel()
        defer {
            source.closeForWindow()
            destination.closeForWindow()
        }
        destination.open(try #require(source.takeWorkspaceForMove(sshWorkspace.id)))
        destination.open(try #require(source.takeWorkspaceForMove(sftpWorkspace.id)))
        ssh.connectIfNeeded(using: app.hostLibrary)
        sftp.connectIfNeeded(using: app.transfers)
        #expect(ssh.pendingAuthentication?.id == sshPrompt.id)
        #expect(sftp.pendingAuthentication?.id == sftpPrompt.id)
        #expect(sftp.path == "/srv")
        #expect(source.workspaces.isEmpty)
        #expect(destination.workspaces.count == 2)
    }

    @Test
    func quickOpenUsesTheSameWindowFactoryAndMoveRequest() throws {
        let app = AppModel(hosts: HostLibraryModel())
        var requests: [UUID] = []
        app.mainWindows.createScene = { requests.append($0) }
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let model = WindowModel(workspaces: [workspace])
        defer { model.closeForWindow() }
        let commands = app.commands.commands(app: app, window: model)
        #expect(commands.contains { $0.target == .newWindow })
        #expect(commands.contains { $0.target == .moveWorkspaceToNewWindow(workspace.id) })
        app.commands.perform(.newWindow, app: app, window: model)
        app.commands.perform(.moveWorkspaceToNewWindow(workspace.id), app: app, window: model)
        #expect(requests.count == 2)
        #expect(requests[0] != requests[1])
        #expect(model.selectedWorkspace === workspace)
    }

    @Test
    func closeCommandConsumesOnePaneAtATimeBeforeClosingTheEmptyWindow() throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let workspace = Workspace.sshSession(host: host)
        let secondPane = Pane.sshSession(host: host)
        workspace.layout = .split(
            SplitNode.Branch(axis: .horizontal, first: workspace.layout, second: .leaf(secondPane)))
        workspace.focusedPaneID = secondPane.id
        let firstSession = try #require(workspace.layout.firstPane.sshSession)
        let secondSession = try #require(secondPane.sshSession)
        firstSession.status = .connected
        secondSession.status = .connected
        let model = WindowModel(workspaces: [workspace])
        let native = nativeWindow()
        defer { native.close() }
        app.mainWindows.register(native, model: model, requestID: nil)

        app.mainWindows.closeSelectionOrWindow(in: model)

        #expect(model.selectedWorkspace === workspace)
        #expect(workspace.panes.count == 1)
        #expect(firstSession.status == .connected)
        #expect(secondSession.status == .disconnected)
        #expect(!model.isClosed)

        app.mainWindows.closeSelectionOrWindow(in: model)

        #expect(model.workspaces.isEmpty)
        #expect(model.canReopen)
        #expect(firstSession.status == .disconnected)
        #expect(!model.isClosed)

        app.mainWindows.closeSelectionOrWindow(in: model)

        #expect(model.isClosed)
        #expect(!model.canReopen)
    }

    @Test(arguments: [WindowDestination.vault, .settings, .assistant, .metrics])
    func closeCommandFromAPinnedPageRespectsNativeCancellation(destination: WindowDestination) throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        session.status = .connected
        let model = WindowModel(workspaces: [workspace])
        model.selectedDestination = destination
        let native = nativeWindow()
        let approval = CloseVeto()
        native.delegate = approval
        defer { native.close() }
        app.mainWindows.register(native, model: model, requestID: nil)

        app.mainWindows.closeSelectionOrWindow(in: model)

        #expect(approval.requests == 1)
        #expect(!model.isClosed)
        #expect(model.selectedDestination == destination)
        #expect(model.workspaces.first === workspace)
        #expect(session.status == .connected)
        #expect(!model.canReopen)
    }

    @Test(arguments: [false, true], [WindowDestination.vault, .settings, .assistant, .metrics])
    func windowCloseWithoutConfirmationOnlyDisconnectsTheRequestedWindowsSessions(
        directClose: Bool, destination: WindowDestination
    ) throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let firstWorkspace = Workspace.sshSession(host: host)
        let secondWorkspace = Workspace.sshSession(host: host)
        let firstSession = try #require(firstWorkspace.focusedPane.sshSession)
        let secondSession = try #require(secondWorkspace.focusedPane.sshSession)
        firstSession.status = .connected
        secondSession.status = .connected
        let firstModel = WindowModel(workspaces: [firstWorkspace])
        let secondModel = WindowModel(workspaces: [secondWorkspace])
        if !directClose { firstModel.selectedDestination = destination }
        let first = nativeWindow()
        let second = nativeWindow()
        defer {
            first.close()
            second.close()
        }
        app.mainWindows.register(first, model: firstModel, requestID: nil)
        app.mainWindows.register(second, model: secondModel, requestID: nil)

        if directClose {
            app.mainWindows.closeWindow(in: firstModel)
        } else {
            app.mainWindows.closeSelectionOrWindow(in: firstModel)
        }

        #expect(firstModel.isClosed)
        #expect(firstModel.workspaces.isEmpty)
        #expect(!firstModel.canReopen)
        #expect(firstSession.status == .disconnected)
        #expect(!secondModel.isClosed)
        #expect(secondModel.selectedWorkspace === secondWorkspace)
        #expect(secondSession.status == .connected)
    }

    @Test(arguments: [WindowDestination.vault, .settings, .assistant, .metrics])
    func closeCommandClosesAnEmptyWindowFromAnyPinnedPage(destination: WindowDestination) {
        let app = AppModel(hosts: HostLibraryModel())
        let model = WindowModel()
        model.selectedDestination = destination
        let native = nativeWindow()
        defer { native.close() }
        app.mainWindows.register(native, model: model, requestID: nil)

        app.mainWindows.closeSelectionOrWindow(in: model)

        #expect(model.isClosed)
    }

    @Test
    func unregisteredWindowFallbackCannotCloseAnotherWindow() {
        let app = AppModel(hosts: HostLibraryModel())
        let registered = WindowModel()
        let unregistered = WindowModel()
        let native = nativeWindow()
        defer { native.close() }
        app.mainWindows.register(native, model: registered, requestID: nil)

        app.mainWindows.closeSelectionOrWindow(in: unregistered)

        #expect(!registered.isClosed)
        #expect(!unregistered.isClosed)
    }

    @Test(arguments: [false, true])
    func quitStartsSessionCleanupWithoutWaitingForPendingEdits(hasPendingEdits: Bool) async throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        session.status = .connected
        let model = WindowModel(workspaces: [workspace])
        app.registerWindow(model)
        let edits = app.sftpEdits.model
        if hasPendingEdits {
            let file = RemoteFile(
                path: "/srv/file", name: "file", kind: .file, size: 4,
                modifiedAt: nil, permissions: 0o644, ownerUID: 0, ownerGID: 0)
            let id = edits.register(
                hostID: host.id, file: file,
                localURL: URL(filePath: "/termind-test-unreadable-edit"), digest: "original")
            edits.update(id) { $0.currentDigest = "edited" }
        }

        // Release this test delegate before yielding so its weak completion tasks
        // cannot send a termination reply to the real test-host application.
        weak var releasedDelegate: AppDelegate?
        autoreleasepool {
            let delegate = AppDelegate()
            releasedDelegate = delegate
            delegate.app = app

            #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
            #expect(model.workspaces.isEmpty)
            #expect(session.status == .disconnected)
            #expect(edits.hasPendingChanges == hasPendingEdits)
            #expect(edits.files.allSatisfy { $0.localError == nil && $0.transferID == nil })
            #expect(delegate.applicationShouldTerminate(NSApp) == .terminateLater)
        }
        #expect(releasedDelegate == nil)
        await app.shutdownForTermination().value
    }

    private final class CloseVeto: NSObject, NSWindowDelegate {
        var requests = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            requests += 1
            return false
        }
    }

    private func nativeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }
}

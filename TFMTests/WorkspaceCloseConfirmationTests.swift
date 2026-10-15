import AppKit
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct WorkspaceCloseConfirmationTests {
    @Test
    func quitAndWindowCloseUseDifferentTitlesActionsAndScope() {
        let quit = WorkspaceCloseConfirmation.application.makeAlert()
        let close = WorkspaceCloseConfirmation.window.makeAlert()

        #expect(quit.messageText == String(localized: AppStrings.Workspace.quitTermindConfirmation))
        #expect(quit.informativeText == String(localized: AppStrings.Workspace.quitTermindWarning))
        #expect(quit.buttons[0].title == String(localized: AppStrings.Workspace.closeTermind))
        #expect(close.messageText == String(localized: AppStrings.Workspace.closeThisWindowConfirmation))
        #expect(close.informativeText == String(localized: AppStrings.Workspace.closeWindowWarning))
        #expect(close.buttons[0].title == String(localized: AppStrings.Workspace.closeWindow))
        for alert in [quit, close] {
            #expect(alert.buttons.count == 2)
            #expect(alert.buttons[1].title == String(localized: AppStrings.Common.cancel))
        }
    }

    @Test(arguments: [WorkspaceCloseConfirmation.window, .application])
    func closeRemainsDefaultAndCancelUsesEscapeAfterLayout(_ scope: WorkspaceCloseConfirmation) {
        let alert = scope.makeAlert()
        alert.layout()

        #expect(alert.buttons[0].keyEquivalent == "\r")
        #expect(alert.window.defaultButtonCell === alert.buttons[0].cell)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }

    @Test(arguments: [WorkspaceCloseConfirmation.window, .application])
    func onlyCloseConfirmationAllowsClosing(_ scope: WorkspaceCloseConfirmation) {
        #expect(scope.confirm { _ in .alertFirstButtonReturn })
        #expect(!scope.confirm { _ in .alertSecondButtonReturn })
        #expect(!scope.confirm { _ in .alertThirdButtonReturn })
        #expect(!scope.confirm { _ in .abort })
    }

    @Test
    func quitChecksWorkspacesAcrossAllRegisteredWindows() {
        let app = AppModel(hosts: HostLibraryModel())
        let empty = WindowModel()
        let populated = WindowModel(workspaces: [.sshSession(host: Host(name: "Server", host: "server.example"))])
        app.registerWindow(empty)
        #expect(!app.hasOpenWorkspaces)
        app.registerWindow(populated)
        #expect(app.hasOpenWorkspaces)
        populated.closeForWindow()
        #expect(!app.hasOpenWorkspaces)
        let other = WindowModel(workspaces: [.sshSession(host: Host(name: "Other", host: "other.example"))])
        app.registerWindow(other)
        #expect(app.hasOpenWorkspaces)
        app.unregisterWindow(other)
        #expect(!app.hasOpenWorkspaces)
        other.closeForWindow()
    }

    @Test
    func windowVetoPreservesWorkspacesAndCanBeRetried() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let model = WindowModel(workspaces: [workspace])
        let native = makeWindow()
        let original = WindowDelegate()
        native.delegate = original
        var approved = false
        var confirmations = 0
        let proxy = WorkspaceWindowCloseDelegate(model: model) {
            confirmations += 1
            return approved
        }
        proxy.attach(to: native)
        defer {
            proxy.attach(to: nil)
            native.close()
            model.closeForWindow()
        }

        #expect(native.delegate?.windowShouldClose?(native) == false)
        #expect(confirmations == 1)
        #expect(!model.isClosed)
        #expect(model.workspaces.first === workspace)
        approved = true
        #expect(native.delegate?.windowShouldClose?(native) == true)
        #expect(confirmations == 2)
        original.allowsClose = false
        #expect(native.delegate?.windowShouldClose?(native) == false)
        #expect(confirmations == 2)
        #expect(original.requests == 3)

        let selector = #selector(WindowDelegate.windowDidResize(_:))
        #expect(proxy.responds(to: selector))
        #expect(proxy.forwardingTarget(for: selector) as? WindowDelegate === original)
        proxy.attach(to: nil)
        #expect(native.delegate === original)
    }

    @Test
    func closingWindowWithManagedSessionDisconnectsWithoutEndingItsRecoveryIdentity() throws {
        let host = Host(name: "Server", host: "server.example")
        let hosts = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        let reference = RemoteSessionReference(
            backend: .tmux, session: .init(id: "session", name: "Managed", identity: Data([1])),
            hostID: host.id, endpoint: "server.example:22", username: "user", ownershipToken: UUID())
        session.sessionPersistence.attachment = reference
        let model = WindowModel(workspaces: [workspace])
        var saved: ClosedWorkspaceRecord?
        model.rememberClosedWindow = { workspaces, _ in
            saved = workspaces.first.map { ClosedWorkspaceRecord($0, hosts: hosts) }
        }
        let native = makeWindow()
        var confirmations = 0
        let proxy = WorkspaceWindowCloseDelegate(model: model) {
            confirmations += 1
            return true
        }
        proxy.attach(to: native)
        defer {
            proxy.attach(to: nil)
            native.close()
            model.closeForWindow()
        }

        #expect(native.delegate?.windowShouldClose?(native) == true)
        #expect(confirmations == 1)
        #expect(!model.persistentClose.isClosing)
        #expect(model.persistentClose.prompt == nil)
        model.closeForWindow()
        #expect(model.isClosed)
        #expect(model.workspaces.isEmpty)
        #expect(session.status == .disconnected)
        #expect(session.sessionPersistence.attachment == reference)
        let restored = try #require(saved?.restore(in: hosts))
        #expect(restored.focusedPane.sshSession?.sessionPersistence.attachment == reference)
    }

    @Test
    func emptyWindowClosesWithoutConfirmation() {
        let model = WindowModel()
        let native = makeWindow()
        let proxy = WorkspaceWindowCloseDelegate(model: model) {
            Issue.record("An empty window should not require confirmation.")
            return false
        }
        proxy.attach(to: native)
        defer {
            proxy.attach(to: nil)
            native.close()
        }
        #expect(native.delegate?.windowShouldClose?(native) == true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        var allowsClose = true
        var requests = 0

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            requests += 1
            return allowsClose
        }

        func windowDidResize(_ notification: Notification) {}
    }
}

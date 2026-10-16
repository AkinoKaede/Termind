import AppKit
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct WorkspaceCloseConfirmationTests {
    @Test func windowCloseFlushesThemeEditsWithoutADiscardPrompt() throws {
        let settings = TerminalSettingsModel()
        let model = WindowModel()
        let theme = TerminalCustomTheme(name: "New", appearance: .both, baseThemeName: "Termind Dark")
        model.openSettings(route: .terminalCustomThemes)
        model.beginEditingTerminalTheme(theme, isNew: true, in: settings)
        let draft = try #require(model.terminalThemeDraft)
        draft.value.configuration = "background = 123456"
        let native = makeWindow()
        defer { native.close() }
        var prompted = false
        let delegate = WorkspaceWindowCloseDelegate(
            model: model,
            confirmDiscardTheme: {
                prompted = true
                return false
            })
        #expect(delegate.windowShouldClose(native))
        #expect(!prompted)
        #expect(settings.themeLibrary.themes.first?.configuration == "background = 123456")
        #expect(model.terminalThemeDraft == nil)
    }

    @Test func quitFlushesThemeEditsAcrossRegisteredWindows() throws {
        let settings = TerminalSettingsModel()
        let app = AppModel(hosts: HostLibraryModel(), terminalSettings: settings)
        defer { app.shutdownForTermination() }
        let windows = [WindowModel(), WindowModel()]
        for (index, window) in windows.enumerated() {
            app.registerWindow(window)
            let theme = TerminalCustomTheme(name: "", appearance: .both, baseThemeName: "Termind Dark")
            window.openSettings(route: .terminalCustomThemes)
            window.beginEditingTerminalTheme(theme, isNew: true, in: settings)
            window.terminalThemeDraft?.value.name = "Theme \(index)"
        }
        #expect(app.hasUnsavedTerminalThemes)
        app.saveTerminalThemeChanges()
        #expect(!app.hasUnsavedTerminalThemes)
        #expect(settings.themeLibrary.themes.count == 2)
    }

    @Test func emptyWindowStillProtectsAnUnsavedThemeDraft() {
        let model = WindowModel()
        let app = AppModel(hosts: HostLibraryModel())
        app.registerWindow(model)
        let draft = TerminalCustomThemeDraft(
            .init(name: "Theme", appearance: .both, baseThemeName: "Termind Dark"), isNew: true)
        model.terminalThemeDraft = draft
        draft.value.configuration = "background = 123456"
        let native = makeWindow()
        var allowsDiscard = false
        let delegate = WorkspaceWindowCloseDelegate(
            model: model, confirmDiscardTheme: { allowsDiscard })
        defer {
            native.close()
            app.shutdownForTermination()
        }
        #expect(app.hasUnsavedTerminalThemes)
        #expect(!delegate.windowShouldClose(native))
        #expect(model.terminalThemeDraft === draft)
        allowsDiscard = true
        #expect(delegate.windowShouldClose(native))
        #expect(model.terminalThemeDraft == nil)
        #expect(!app.hasUnsavedTerminalThemes)
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
    func populatedWindowClosesWithoutAPromptAndStillRespectsTheNativeDelegate() {
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let model = WindowModel(workspaces: [workspace])
        let native = makeWindow()
        let original = WindowDelegate()
        native.delegate = original
        let proxy = WorkspaceWindowCloseDelegate(model: model) {
            Issue.record("Live connections do not need a close confirmation.")
            return false
        }
        proxy.attach(to: native)
        defer {
            proxy.attach(to: nil)
            native.close()
            model.closeForWindow()
        }

        #expect(native.delegate?.windowShouldClose?(native) == true)
        #expect(!model.isClosed)
        #expect(model.workspaces.first === workspace)
        original.allowsClose = false
        #expect(native.delegate?.windowShouldClose?(native) == false)
        original.allowsClose = true
        #expect(native.delegate?.windowShouldClose?(native) == true)
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
        let proxy = WorkspaceWindowCloseDelegate(model: model) {
            Issue.record("A managed session does not need a close confirmation.")
            return false
        }
        proxy.attach(to: native)
        defer {
            proxy.attach(to: nil)
            native.close()
            model.closeForWindow()
        }

        #expect(native.delegate?.windowShouldClose?(native) == true)
        #expect(!model.persistentClose.isClosing)
        model.closeForWindow()
        #expect(model.isClosed)
        #expect(model.workspaces.isEmpty)
        #expect(session.status == .disconnected)
        #expect(session.sessionPersistence.attachment == reference)
        let restored = try #require(saved?.restore(in: hosts))
        #expect(restored.focusedPane.sshSession?.sessionPersistence.attachment == reference)
    }

    @Test func failedManagedPaneCloseDisconnectsAndKeepsItsRecoveryReference() async throws {
        let host = Host(name: "Server", host: "server.example")
        let hosts = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        let reference = RemoteSessionReference(
            backend: .zellij, session: .init(id: "session", name: "Managed", identity: Data([1])),
            hostID: host.id, endpoint: "server.example:22", username: "user", ownershipToken: UUID())
        session.sessionPersistence.attachment = reference
        let model = WindowModel(workspaces: [workspace])
        var saved: ClosedWorkspaceRecord?
        model.rememberClosedWorkspace = { saved = ClosedWorkspaceRecord($0, hosts: hosts) }
        defer { model.closeForWindow() }

        // There is no live SSH transport to end the remote session.
        model.closeSelected()
        for _ in 0..<200 {
            if model.workspaces.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(model.workspaces.isEmpty)
        #expect(session.sessionPersistence.attachment == reference)
        #expect(session.status == .disconnected)
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

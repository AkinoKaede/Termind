import AppKit
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct DockMenuTests {
    @Test
    func newWindowIsDisabledUntilTheAppAndSceneFactoryAreReady() throws {
        let delegate = AppDelegate()
        let initial = try #require(delegate.applicationDockMenu(NSApp))
        #expect(initial.items.count == 1)
        #expect(!initial.autoenablesItems)
        #expect(initial.items[0].image == nil)
        #expect(!initial.items[0].isEnabled)
        initial.update()
        #expect(!initial.items[0].isEnabled)

        let app = AppModel(hosts: HostLibraryModel())
        delegate.app = app
        let unregistered = try #require(delegate.applicationDockMenu(NSApp))
        #expect(!unregistered.items[0].isEnabled)

        var requests: [UUID] = []
        app.mainWindows.registerWindowCreation { requests.append($0) }
        let ready = try #require(delegate.applicationDockMenu(NSApp))
        #expect(ready.items[0].isEnabled)
        #expect(ready.items[0].keyEquivalent.isEmpty)

        // An already presented menu must also tolerate losing its factory.
        app.mainWindows.createScene = nil
        ready.performActionForItem(at: 0)
        #expect(requests.isEmpty)
        #expect(try #require(delegate.applicationDockMenu(NSApp)).items[0].isEnabled == false)
    }

    @Test(.requiresVisibleWindow, arguments: [false, true])
    func repeatedDockActionsCreateDistinctWelcomeWindowsWithoutAnExistingWindow(closePreviousWindow: Bool) throws {
        let app = AppModel(hosts: HostLibraryModel())
        let delegate = AppDelegate()
        delegate.app = app
        if closePreviousWindow {
            let previous = nativeWindow()
            let previousModel = WindowModel()
            app.mainWindows.register(previous, model: previousModel, requestID: nil)
            previous.close()
            #expect(previousModel.isClosed)
        }
        var requests: [UUID] = []
        app.mainWindows.registerWindowCreation { requests.append($0) }
        let menu = try #require(delegate.applicationDockMenu(NSApp))
        #expect(menu.items[0].isEnabled)

        menu.performActionForItem(at: 0)
        #expect(requests.count == 1)
        menu.performActionForItem(at: 0)
        try #require(requests.count == 2)
        #expect(Set(requests).count == 2)

        let first = nativeWindow()
        let second = nativeWindow()
        defer {
            first.close()
            second.close()
        }
        let firstModel = WindowModel()
        let secondModel = WindowModel()
        app.mainWindows.register(first, model: firstModel, requestID: requests[0])
        app.mainWindows.register(second, model: secondModel, requestID: requests[1])
        for model in [firstModel, secondModel] {
            #expect(model.selectedDestination == .vault)
            #expect(model.vaultDestination == .welcome)
            #expect(model.workspaces.isEmpty)
        }
        firstModel.assistantQuery = "Only the first window"
        #expect(secondModel.assistantQuery.isEmpty)
    }

    @Test(.requiresVisibleWindow, arguments: [false, true])
    func dockNewWindowPreservesTheExistingPageAndWorkspaceEvenInFullScreen(fullScreen: Bool) throws {
        let host = Host(name: "Server", host: "server.example")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let delegate = AppDelegate()
        delegate.app = app
        let workspace = Workspace.sshSession(host: host)
        let session = try #require(workspace.focusedPane.sshSession)
        session.status = .connected
        let sourceModel = WindowModel(workspaces: [workspace])
        sourceModel.selectedDestination = .metrics
        let source = nativeWindow()
        let destination = nativeWindow()
        defer {
            source.close()
            destination.close()
        }
        app.mainWindows.register(source, model: sourceModel, requestID: nil)
        if fullScreen {
            NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: source)
            NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: source)
        }
        var requests: [UUID] = []
        app.mainWindows.registerWindowCreation { requests.append($0) }
        let menu = try #require(delegate.applicationDockMenu(NSApp))

        menu.performActionForItem(at: 0)

        #expect(requests.count == 1)
        let destinationModel = WindowModel()
        let request = try #require(requests.first)
        app.mainWindows.register(destination, model: destinationModel, requestID: request)
        #expect(destinationModel.selectedDestination == .vault)
        #expect(destinationModel.vaultDestination == .welcome)
        #expect(destinationModel.workspaces.isEmpty)
        #expect(sourceModel.selectedDestination == .metrics)
        #expect(sourceModel.workspaces.count == 1)
        #expect(sourceModel.workspaces.first === workspace)
        #expect(sourceModel.hostChooser == nil)
        #expect(session.status == .connected)
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

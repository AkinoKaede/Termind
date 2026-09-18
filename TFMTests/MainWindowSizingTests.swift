import AppKit
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.serialized)
@MainActor
struct MainWindowSizingTests {
    @Test
    func storedSizesRoundTripAndInvalidValuesUseTheDefault() throws {
        try withDefaults { defaults in
            let fallback = CGSize(width: 1180, height: 740)
            #expect(MainWindowSizeStore(defaults: defaults).defaultSize == fallback)
            for value in [[], [900], [900, 600, 1], [-1, 600], [900, 0]] as [[Double]] {
                defaults.set(value, forKey: DesktopSettingsKey.mainWindowSize)
                #expect(MainWindowSizeStore(defaults: defaults).defaultSize == fallback)
            }
            defaults.set("invalid", forKey: DesktopSettingsKey.mainWindowSize)
            let store = MainWindowSizeStore(defaults: defaults)
            let size = CGSize(width: 923.5, height: 617.5)
            store.save(size)
            store.save(CGSize(width: CGFloat.infinity, height: 600))
            store.save(CGSize(width: 900, height: CGFloat.nan))
            #expect(MainWindowSizeStore(defaults: defaults).size == size)
            let isolated = MainWindowSizeStore()
            isolated.save(CGSize(width: 800, height: 500))
            #expect(MainWindowSizeStore(defaults: defaults).size == size)
        }
    }

    @Test
    func requestsCaptureTheirOwnSourceAndRepeatedCopiesDoNotAccumulateTitlebarHeight() throws {
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let firstModel = WindowModel()
        let secondModel = WindowModel()
        let first = nativeWindow(size: CGSize(width: 900, height: 600))
        let second = nativeWindow(size: CGSize(width: 1000, height: 650))
        var natives = [first, second]
        var models = [firstModel, secondModel]
        defer { for window in natives { window.close() } }
        app.mainWindows.register(first, model: firstModel, requestID: nil)
        app.mainWindows.register(second, model: secondModel, requestID: nil)
        post(NSWindow.didBecomeKeyNotification, first)
        let firstRequest = try #require(app.mainWindows.newWindow(from: firstModel))
        let secondRequest = try #require(app.mainWindows.newWindow(from: secondModel))
        first.setContentSize(CGSize(width: 960, height: 660))

        for (request, expected) in [
            (secondRequest, CGSize(width: 1000, height: 650)),
            (firstRequest, CGSize(width: 900, height: 600)),
        ] {
            let native = nativeWindow()
            let model = WindowModel()
            natives.append(native)
            models.append(model)
            app.mainWindows.register(native, model: model, requestID: request)
            #expect(native.frame.size == expected)
        }
        for _ in 0..<4 {
            let request = try #require(app.mainWindows.newWindow(from: models.last))
            let native = nativeWindow()
            let model = WindowModel()
            natives.append(native)
            models.append(model)
            app.mainWindows.register(native, model: model, requestID: request)
            #expect(native.frame.size == CGSize(width: 900, height: 600))
        }
        let last = try #require(natives.last)
        let model = try #require(models.last)
        last.setContentSize(CGSize(width: 940, height: 640))
        app.mainWindows.register(last, model: model, requestID: firstRequest)
        #expect(last.frame.size == CGSize(width: 940, height: 640))
    }

    @Test
    func registrationConfiguresFullSizeContentBeforeApplyingTheSourceSize() throws {
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let source = nativeWindow(size: CGSize(width: 920, height: 620))
        let sourceModel = WindowModel()
        let targetModel = WindowModel()
        let target = NSWindow(
            contentRect: CGRect(x: 100, y: 150, width: 800, height: 600),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        target.isReleasedWhenClosed = false
        defer {
            source.close()
            target.close()
        }
        app.mainWindows.register(source, model: sourceModel, requestID: nil)
        let request = try #require(app.mainWindows.newWindow(from: sourceModel))
        target.contentView = MainWindowRegistrationView(
            coordinator: app.mainWindows, model: targetModel, requestID: request)
        #expect(target.styleMask.contains(.fullSizeContentView))
        #expect(target.titlebarAppearsTransparent)
        #expect(target.frame.size == source.frame.size)
    }

    @Test
    func closingAllWindowsAndDockReopeningUsesTheSavedSize() throws {
        try withDefaults { defaults in
            let app = AppModel(hosts: HostLibraryModel(), windowSizeStore: MainWindowSizeStore(defaults: defaults))
            let original = nativeWindow()
            let model = WindowModel()
            app.mainWindows.register(original, model: model, requestID: nil)
            let size = CGSize(width: 950, height: 620)
            original.setContentSize(size)
            post(NSWindow.didEndLiveResizeNotification, original)
            original.close()
            var request: UUID?
            app.mainWindows.createScene = { request = $0 }
            #expect(!app.mainWindows.handleReopen())
            let reopened = nativeWindow()
            defer { reopened.close() }
            let reopenedModel = WindowModel()
            let reopenRequest = try #require(request)
            app.mainWindows.register(reopened, model: reopenedModel, requestID: reopenRequest)
            #expect(reopened.frame.size == size)
            #expect(reopenedModel.workspaces.isEmpty)
            #expect(MainWindowSizeStore(defaults: defaults).defaultSize == size)
        }
    }

    @Test
    func relaunchDefaultDoesNotOverrideIndividualRestoredFrames() throws {
        try withDefaults { defaults in
            MainWindowSizeStore(defaults: defaults).save(CGSize(width: 1050, height: 700))
            let app = AppModel(hosts: HostLibraryModel(), windowSizeStore: MainWindowSizeStore(defaults: defaults))
            #expect(app.windowSizeStore.defaultSize == CGSize(width: 1050, height: 700))
            let first = nativeWindow(size: CGSize(width: 910, height: 610))
            let second = nativeWindow(size: CGSize(width: 980, height: 680))
            let firstModel = WindowModel()
            let secondModel = WindowModel()
            defer {
                first.close()
                second.close()
            }
            let firstFrame = first.frame
            let secondFrame = second.frame
            app.mainWindows.register(first, model: firstModel, requestID: nil)
            app.mainWindows.register(second, model: secondModel, requestID: UUID())
            #expect(first.frame == firstFrame)
            #expect(second.frame == secondFrame)
            #expect(firstModel.workspaces.isEmpty && secondModel.workspaces.isEmpty)
        }
    }

    @Test
    func fullScreenCommandConnectsWhileExplicitNewWindowUsesTheOrdinarySize() throws {
        let app = AppModel(hosts: HostLibraryModel())
        var requests: [UUID] = []
        app.mainWindows.createScene = { requests.append($0) }
        let model = WindowModel()
        let normalSize = CGSize(width: 900, height: 600)
        let native = nativeWindow(size: normalSize)
        let destination = nativeWindow()
        let destinationModel = WindowModel()
        defer {
            native.close()
            destination.close()
        }
        app.mainWindows.register(native, model: model, requestID: nil)
        post(NSWindow.willEnterFullScreenNotification, native)
        native.setContentSize(CGSize(width: 1300, height: 800))
        post(NSWindow.didEnterFullScreenNotification, native)
        post(NSWindow.didResizeNotification, native)
        app.mainWindows.performNewWindowCommand(from: model)
        #expect(app.mainWindows.isFullScreen(model))
        #expect(model.hostChooser == .connect)
        #expect(model.workspaces.isEmpty)
        #expect(requests.isEmpty)
        #expect(app.windowSizeStore.size == normalSize)

        app.commands.perform(.newWindow, app: app, window: model)
        let newWindowRequest = try #require(requests.first)
        app.mainWindows.register(destination, model: destinationModel, requestID: newWindowRequest)
        #expect(destination.frame.size == normalSize)

        post(NSWindow.willExitFullScreenNotification, native)
        native.setContentSize(CGSize(width: 1100, height: 700))
        post(NSWindow.didResizeNotification, native)
        #expect(app.windowSizeStore.size == normalSize)
        native.setContentSize(normalSize)
        post(NSWindow.didExitFullScreenNotification, native)
        model.hostChooser = nil
        app.mainWindows.performNewWindowCommand(from: model)
        #expect(!app.mainWindows.isFullScreen(model))
        #expect(model.hostChooser == nil)
        #expect(requests.count == 2)
    }

    @Test
    func backgroundAndAuxiliaryWindowsCannotReplaceTheLastUsedSizeDuringQuit() {
        let app = AppModel(hosts: HostLibraryModel())
        let first = nativeWindow(size: CGSize(width: 900, height: 600))
        let second = nativeWindow(size: CGSize(width: 1000, height: 650))
        let auxiliary = nativeWindow(size: CGSize(width: 560, height: 240))
        let firstModel = WindowModel()
        let secondModel = WindowModel()
        defer {
            first.close()
            second.close()
            auxiliary.close()
        }
        app.mainWindows.register(first, model: firstModel, requestID: nil)
        app.mainWindows.register(second, model: secondModel, requestID: nil)
        post(NSWindow.didBecomeKeyNotification, first)
        second.setContentSize(CGSize(width: 1100, height: 700))
        post(NSWindow.didResizeNotification, second)
        post(NSWindow.didBecomeKeyNotification, auxiliary)
        post(NSWindow.didResizeNotification, auxiliary)
        #expect(app.windowSizeStore.size == first.frame.size)
        app.mainWindows.saveSizeForTermination()
        let saved = app.windowSizeStore.size
        first.close()
        post(NSWindow.didBecomeKeyNotification, second)
        second.close()
        #expect(app.windowSizeStore.size == saved)
    }

    @Test
    func workspaceMovesInheritSizeAndNewWindowsRespectTheirContentMinimum() throws {
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.example"))
        let model = WindowModel(workspaces: [workspace])
        let native = nativeWindow(size: CGSize(width: 910, height: 610))
        let destination = nativeWindow()
        let target = WindowModel()
        defer {
            native.close()
            destination.close()
        }
        app.mainWindows.register(native, model: model, requestID: nil)
        let request = try #require(app.mainWindows.moveWorkspace(workspace.id, from: model))
        app.mainWindows.register(destination, model: target, requestID: request)
        #expect(destination.frame.size == native.frame.size)
        #expect(target.selectedWorkspace === workspace)

        native.setContentSize(CGSize(width: 400, height: 440))
        let smallRequest = try #require(app.mainWindows.newWindow(from: model))
        let constrained = nativeWindow()
        let constrainedModel = WindowModel()
        defer { constrained.close() }
        constrained.contentMinSize = CGSize(width: 700, height: 500)
        app.mainWindows.register(constrained, model: constrainedModel, requestID: smallRequest)
        #expect(constrained.frame.width >= 700)
        #expect(constrained.frame.height >= 500)
    }

    @Test
    func fittingToASmallerScreenRetainsTheTopEdgeWhenPossible() {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let oversized = CGRect(x: 100, y: 0, width: 1600, height: 1000)
        #expect(MainWindowCoordinator.fittingFrame(oversized, within: screen) == screen)
        let fitting = CGRect(x: -1100, y: 200, width: 900, height: 600)
        #expect(MainWindowCoordinator.fittingFrame(fitting, within: screen) == fitting)
    }

    private func nativeWindow(size: CGSize = CGSize(width: 800, height: 600)) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 100, y: 150), size: size),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    private func post(_ name: Notification.Name, _ window: NSWindow) {
        NotificationCenter.default.post(name: name, object: window)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "MainWindowSizingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}

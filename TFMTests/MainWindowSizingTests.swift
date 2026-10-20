// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftData
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPersistence
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
            #expect(MainWindowSizeStore(defaults: defaults).defaultSidebarWidth == 320)
            #expect(MainWindowSizeStore(defaults: defaults).defaultShowsSidebar)
            for value in [[], [900], [900, 600, 1], [-1, 600], [900, 0]] as [[Double]] {
                defaults.set(value, forKey: DesktopSettingsKey.mainWindowSize)
                #expect(MainWindowSizeStore(defaults: defaults).defaultSize == fallback)
            }
            defaults.set("invalid", forKey: DesktopSettingsKey.mainWindowSize)
            let store = MainWindowSizeStore(defaults: defaults)
            let size = CGSize(width: 923.5, height: 617.5)
            store.save(size)
            store.saveSidebar(width: 468, isPresented: false)
            store.save(CGSize(width: CGFloat.infinity, height: 600))
            store.save(CGSize(width: 900, height: CGFloat.nan))
            store.saveSidebar(width: .nan, isPresented: true)
            #expect(MainWindowSizeStore(defaults: defaults).size == size)
            #expect(MainWindowSizeStore(defaults: defaults).sidebarWidth == 468)
            #expect(!MainWindowSizeStore(defaults: defaults).defaultShowsSidebar)
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
        firstModel.sidebar.preferredWidth = 450
        firstModel.showsSidebar = false
        secondModel.sidebar.preferredWidth = 380
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
            #expect(model.sidebar.preferredWidth == (request == firstRequest ? 450 : 380))
            #expect(model.showsSidebar == (request != firstRequest))
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
    func fullScreenCommandCreatesAFullScreenRequestWithTheOrdinarySize() throws {
        let app = AppModel(hosts: HostLibraryModel())
        var requests: [UUID] = []
        app.mainWindows.createScene = { requests.append($0) }
        let model = WindowModel()
        model.sidebar.preferredWidth = 480
        model.showsSidebar = false
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
        #expect(model.hostChooser == nil)
        #expect(model.workspaces.isEmpty)
        let firstRequest = try #require(requests.first)
        let firstLayout = try #require(app.mainWindows.requestedLayout(for: firstRequest))
        #expect(firstLayout.size == normalSize)
        #expect(firstLayout.sidebarWidth == 480)
        #expect(!firstLayout.showsSidebar)
        #expect(firstLayout.isFullScreen)
        #expect(app.windowSizeStore.size == normalSize)

        app.commands.perform(.newWindow, app: app, window: model)
        let newWindowRequest = try #require(requests.last)
        app.mainWindows.register(destination, model: destinationModel, requestID: newWindowRequest)
        #expect(destination.frame.size == normalSize)
        #expect(destinationModel.sidebar.preferredWidth == 480)
        #expect(!destinationModel.showsSidebar)

        post(NSWindow.willExitFullScreenNotification, native)
        native.setContentSize(CGSize(width: 1100, height: 700))
        post(NSWindow.didResizeNotification, native)
        #expect(app.windowSizeStore.size == normalSize)
        native.setContentSize(normalSize)
        post(NSWindow.didExitFullScreenNotification, native)
        app.mainWindows.performNewWindowCommand(from: model)
        #expect(!app.mainWindows.isFullScreen(model))
        #expect(model.hostChooser == nil)
        #expect(requests.count == 3)
        #expect(app.mainWindows.requestedLayout(for: requests[2])?.isFullScreen == false)
    }

    @Test
    func lastWindowLayoutIsUsedWhenNoSourceRemains() throws {
        try withDefaults { defaults in
            let store = MainWindowSizeStore(defaults: defaults)
            let app = AppModel(hosts: HostLibraryModel(), windowSizeStore: store)
            app.mainWindows.createScene = { _ in }
            let source = nativeWindow(size: CGSize(width: 960, height: 660))
            let sourceModel = WindowModel()
            sourceModel.sidebar.preferredWidth = 444
            sourceModel.showsSidebar = false
            app.mainWindows.register(source, model: sourceModel, requestID: nil)
            source.close()

            let request = try #require(app.mainWindows.newWindow())
            let layout = try #require(app.mainWindows.requestedLayout(for: request))
            #expect(layout.size == CGSize(width: 960, height: 660))
            #expect(layout.sidebarWidth == 444)
            #expect(!layout.showsSidebar)
            #expect(!layout.isFullScreen)
            let targetModel = WindowModel()
            app.mainWindows.configure(targetModel, for: request)
            #expect(targetModel.sidebar.preferredWidth == 444)
            #expect(!targetModel.showsSidebar)
        }
    }

    @Test
    func hiddenSidebarKeepsItsLastMeasuredWidth() {
        let app = AppModel(hosts: HostLibraryModel())
        let source = nativeWindow()
        let model = WindowModel()
        defer { source.close() }
        app.mainWindows.register(source, model: model, requestID: nil)
        app.mainWindows.recordSidebarWidth(456, for: model)
        #expect(model.sidebar.preferredWidth == 456)
        model.showsSidebar = false
        app.mainWindows.recordSidebarWidth(0, for: model)
        #expect(model.sidebar.preferredWidth == 456)
        model.showsSidebar = true
        #expect(model.sidebar.preferredWidth == 456)
    }

    @Test
    func firstDefaultSidebarMeasurementCannotReplaceTheRequestedWidth() throws {
        let app = AppModel(hosts: HostLibraryModel())
        app.mainWindows.createScene = { _ in }
        let source = nativeWindow()
        let sourceModel = WindowModel()
        sourceModel.sidebar.preferredWidth = 260
        let target = nativeWindow()
        let targetModel = WindowModel()
        defer {
            source.close()
            target.close()
        }
        app.mainWindows.register(source, model: sourceModel, requestID: nil)
        let request = try #require(app.mainWindows.newWindow(from: sourceModel))
        app.mainWindows.configure(targetModel, for: request)
        app.mainWindows.register(target, model: targetModel, requestID: request)

        app.mainWindows.recordSidebarWidth(Metrics.Sidebar.ideal, for: targetModel)
        #expect(targetModel.sidebar.preferredWidth == 260)
        #expect(targetModel.sidebar.observedWidth == nil)

        app.mainWindows.recordSidebarWidth(260, for: targetModel)
        #expect(targetModel.sidebar.observedWidth == 260)
        app.mainWindows.recordSidebarWidth(390, for: targetModel)
        #expect(targetModel.sidebar.observedWidth == 390)
        #expect(targetModel.sidebar.preferredWidth == 390)
    }

    @Test(.requiresVisibleWindow)
    func visibleNewWindowUsesTheSourceSidebarWidth() async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let sourceModel = WindowModel()
        sourceModel.sidebar.preferredWidth = 456
        let source = hostedWindow(app: app, model: sourceModel, container: container)
        var destination: NSWindow?
        defer {
            destination?.orderOut(nil)
            destination?.contentViewController = nil
            destination?.close()
            source.orderOut(nil)
            source.contentViewController = nil
            source.close()
            app.shutdownForTermination()
        }
        app.mainWindows.createScene = { _ in }
        source.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(sourceModel.sidebar.preferredWidth - 456) < 3)

        let request = try #require(app.mainWindows.newWindow(from: sourceModel))
        let targetModel = WindowModel()
        app.mainWindows.configure(targetModel, for: request)
        let target = hostedWindow(app: app, model: targetModel, requestID: request, container: container)
        destination = target
        target.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(targetModel.sidebar.preferredWidth - 456) < 3)
        #expect(abs(target.frame.width - source.frame.width) < 2)
    }

    @Test(.requiresVisibleWindow)
    func visibleFirstWorkspaceMoveUsesTheSourceSidebarWidth() async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let workspace = Workspace.sshSession(host: Host(name: "Server", host: "server.invalid"))
        let sourceModel = WindowModel(workspaces: [workspace])
        sourceModel.sidebar.preferredWidth = 260
        let source = hostedWindow(app: app, model: sourceModel, container: container)
        var destination: NSWindow?
        defer {
            destination?.orderOut(nil)
            destination?.contentViewController = nil
            destination?.close()
            source.orderOut(nil)
            source.contentViewController = nil
            source.close()
            app.shutdownForTermination()
        }
        app.mainWindows.createScene = { _ in }
        source.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(sourceModel.sidebar.preferredWidth - 260) < 3)
        #expect(abs((sourceModel.sidebar.observedWidth ?? 0) - 260) < 3)
        let request = try #require(app.mainWindows.moveWorkspace(workspace.id, from: sourceModel))
        let targetModel = WindowModel()
        let target = hostedWindow(app: app, model: targetModel, requestID: request, container: container)
        destination = target
        target.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(600))
        #expect(abs(targetModel.sidebar.preferredWidth - 260) < 3)
        #expect(abs((targetModel.sidebar.observedWidth ?? 0) - 260) < 3)
        #expect(abs(target.frame.width - source.frame.width) < 2)
    }

    @Test(.requiresVisibleWindow)
    func fullScreenCommandMakesTheNewWindowFullScreen() async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let sourceModel = WindowModel()
        sourceModel.sidebar.preferredWidth = 440
        let source = hostedWindow(app: app, model: sourceModel, container: container)
        var destination: NSWindow?
        defer {
            destination?.orderOut(nil)
            destination?.contentViewController = nil
            destination?.close()
            source.orderOut(nil)
            source.contentViewController = nil
            source.close()
            app.shutdownForTermination()
        }
        source.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil(stage: "source window become key") {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            source.orderFrontRegardless()
            source.makeMain()
            source.makeKey()
            return source.isKeyWindow
        }
        post(NSWindow.willEnterFullScreenNotification, source)
        post(NSWindow.didEnterFullScreenNotification, source)
        var requestID: UUID?
        app.mainWindows.createScene = { requestID = $0 }

        app.mainWindows.performNewWindowCommand(from: sourceModel)
        let request = try #require(requestID)
        let targetModel = WindowModel()
        app.mainWindows.configure(targetModel, for: request)
        let target = hostedWindow(app: app, model: targetModel, requestID: request, container: container)
        destination = target
        target.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil(stage: "new window become key") {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            target.orderFrontRegardless()
            target.makeMain()
            target.makeKey()
            return target.isKeyWindow
        }
        try await waitUntil(timeout: .seconds(15), stage: "new window enter full screen") {
            app.mainWindows.isFullScreen(targetModel)
        }
        #expect(target.styleMask.contains(.fullScreen))
        #expect(abs(targetModel.sidebar.preferredWidth - 440) < 3)
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

    private func hostedWindow(
        app: AppModel, model: WindowModel, requestID: UUID? = nil,
        container: SwiftData.ModelContainer
    ) -> NSWindow {
        let root = RootView(window: model, requestID: requestID)
            .environment(app)
            .modelContainer(container)
        let controller = NSHostingController(rootView: root)
        controller.sizingOptions = []
        let window = nativeWindow(size: CGSize(width: 1100, height: 720))
        window.isRestorable = false
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentViewController = controller
        window.setContentSize(CGSize(width: 1100, height: 720))
        return window
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), stage: String = "condition", condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(stage)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
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

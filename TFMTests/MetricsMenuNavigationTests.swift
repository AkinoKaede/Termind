// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized)
@MainActor
struct MetricsMenuNavigationTests {
    @Test
    func detailsReuseTheMostRecentWindowAndPreserveOtherWindows() throws {
        let fixture = MetricsMenuFixture()
        defer { fixture.close() }
        let first = WindowModel()
        let second = WindowModel()
        let firstNative = fixture.register(first)
        _ = fixture.register(second)
        let servers = fixture.app.serverMetrics.servers
        let server = try #require(servers.first)
        let other = try #require(servers.dropFirst().first)
        first.metricsHostID = other.id
        first.metricsDetailPage = .processes
        second.selectedDestination = .assistant
        second.metricsHostID = other.id
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: firstNative)

        fixture.app.mainWindows.openMetrics(hostID: server.id)
        #expect(first.selectedDestination == .metrics)
        #expect(first.metricsHostID == server.id)
        #expect(first.metricsDetailPage == .status)
        #expect(second.selectedDestination == .assistant)
        #expect(second.metricsHostID == other.id)
        #expect(fixture.requests.isEmpty)

        first.metricsDetailPage = .processes
        fixture.app.mainWindows.openMetrics(hostID: server.id)
        #expect(first.metricsDetailPage == .processes)
        first.selectedDestination = .vault
        fixture.app.mainWindows.openMetrics()
        #expect(first.selectedDestination == .metrics)
        #expect(first.metricsHostID == server.id)
        #expect(first.metricsDetailPage == .processes)

        fixture.app.serverMetrics.remove(server.id)
        fixture.app.mainWindows.openMetrics(hostID: server.id)
        #expect(first.selectedDestination == .metrics)
        #expect(first.metricsHostID == nil)
    }

    @Test
    func detailsRestoreAMinimizedWindowFromTheBackground() async throws {
        let fixture = MetricsMenuFixture()
        defer { fixture.close() }
        let model = WindowModel()
        let window = fixture.register(model)
        let server = try #require(fixture.app.serverMetrics.servers.first)
        try await activate(window)
        window.miniaturize(nil)
        try await waitUntil { window.isMiniaturized }
        NSApp.hide(nil)
        try await waitUntil { !NSApp.isActive }
        fixture.app.mainWindows.openMetrics(hostID: server.id)
        try await waitUntil { !window.isMiniaturized && window.isKeyWindow && NSApp.isActive }
        #expect(model.metricsHostID == server.id)
        #expect(fixture.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func aNewWindowReceivesItsHostAndRevalidatesItAtRegistration(removeBeforeRegistration: Bool) throws {
        let fixture = MetricsMenuFixture()
        defer { fixture.close() }
        let server = try #require(fixture.app.serverMetrics.servers.first)
        fixture.app.mainWindows.openMetrics(hostID: server.id)
        #expect(fixture.requests.count == 1)
        let request = try #require(fixture.requests.first)
        let welcomeRequest = try #require(fixture.app.mainWindows.newWindow())
        if removeBeforeRegistration { fixture.app.serverMetrics.remove(server.id) }

        let welcome = WindowModel()
        _ = fixture.register(welcome, requestID: welcomeRequest)
        let metrics = WindowModel()
        _ = fixture.register(metrics, requestID: request)
        #expect(welcome.selectedDestination == .vault)
        #expect(welcome.metricsHostID == nil)
        #expect(metrics.selectedDestination == .metrics)
        #expect(metrics.metricsHostID == (removeBeforeRegistration ? nil : server.id))
        #expect(metrics.metricsDetailPage == .status)
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese])
    func theWholeRowOpensTheCorrectHostInEveryConnectionState(language: AppLanguage) async throws {
        let fixture = MetricsMenuFixture(language: language)
        defer { fixture.close() }
        var opened: [UUID] = []
        var openedMainWindow = false
        let menu = MetricsMenuView(
            model: fixture.app.serverMetrics, openMetrics: { openedMainWindow = true },
            openDetails: { opened.append($0) }
        )
        .environment(\.locale, language.locale)
        .environment(\.colorScheme, .light)
        .background(Color(nsColor: .windowBackgroundColor))
        let window = fixture.makeWindow()
        window.setContentSize(MetricsMenuView.preferredSize(serverCount: fixture.app.serverMetrics.servers.count))
        window.contentViewController = NSHostingController(rootView: menu)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let server = try #require(fixture.app.serverMetrics.servers.dropFirst().first)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        #expect(view.bounds.size == MetricsMenuView.preferredSize(serverCount: fixture.app.serverMetrics.servers.count))
        try capture(window, name: "metrics-menu-\(language.rawValue)")

        // Name, instruments and empty padding must all belong to the button.
        let top = 49.0 + 119
        for (index, point) in [
            CGPoint(x: 30, y: top + 20),
            CGPoint(x: 190, y: top + 59),
            CGPoint(x: 3, y: top + 115),
        ].enumerated() {
            try clickFromTop(point, in: view, window: window)
            try await Task.sleep(for: .milliseconds(30))
            #expect(opened.count == index + 1, "Row click at \(point)")
        }
        #expect(opened == Array(repeating: server.id, count: 3))

        server.point = nil
        server.isConnecting = true
        try await Task.sleep(for: .milliseconds(30))
        try clickFromTop(CGPoint(x: 190, y: top + 59), in: view, window: window)
        server.isConnecting = false
        server.needsAttention = true
        server.status = "Fixture connection failure"
        server.journey.fail("Fixture connection failure")
        try await Task.sleep(for: .milliseconds(30))
        try clickFromTop(CGPoint(x: 190, y: top + 59), in: view, window: window)
        server.selection.enabled = false
        server.needsAttention = false
        server.status = "Paused"
        try await Task.sleep(for: .milliseconds(30))
        try clickFromTop(CGPoint(x: 190, y: top + 59), in: view, window: window)
        #expect(opened == Array(repeating: server.id, count: 6))
        #expect(!openedMainWindow)
    }

    @Test
    func choosingAHostClosesTheMenuAndRoutesItsIdentifier() async throws {
        let fixture = MetricsMenuFixture()
        defer { fixture.close() }
        let suite = "termind.metrics-menu.tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: DesktopSettingsKey.showMetricsInMenuBar)
        let popover = NSPopover()
        popover.animates = false
        let controller = MetricsMenuBarController(defaults: defaults, popover: popover)
        defer {
            controller.stop()
            defaults.removePersistentDomain(forName: suite)
        }
        var opened: UUID?
        controller.openDetails = {
            #expect(!popover.isShown)
            opened = $0
        }
        let anchor = fixture.makeWindow()
        try await activate(anchor)
        controller.start(fixture.app.serverMetrics)
        try await Task.sleep(for: .milliseconds(200))
        controller.togglePopover()
        let server = try #require(fixture.app.serverMetrics.servers.first)
        try await waitUntil { popover.isShown }
        let view = try #require(popover.contentViewController?.view)
        let window = try #require(view.window)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try clickFromTop(CGPoint(x: 190, y: 49 + 59), in: view, window: window)
        #expect(opened == server.id)
        try await waitUntil { !window.isVisible }
    }

    private func activate(_ window: NSWindow) async throws {
        try await waitUntil {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
            return window.isKeyWindow && NSApp.isActive
        }
    }

    private func clickFromTop(_ point: CGPoint, in view: NSView, window: NSWindow) throws {
        let local = CGPoint(x: point.x, y: view.isFlipped ? point.y : view.bounds.height - point.y)
        try click(view.convert(local, to: nil), in: window)
    }

    private func click(_ point: CGPoint, in window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), sourceLocation: sourceLocation)
    }

    private func capture(_ window: NSWindow, name: String) throws {
        let view = try #require(window.contentView)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        try data.write(to: FileManager.default.temporaryDirectory.appending(path: "\(name).png"))
    }
}

@MainActor
private final class MetricsMenuFixture {
    let app: AppModel
    var requests: [UUID] = []
    private var windows: [NSWindow] = []

    init(language: AppLanguage = .english) {
        let hosts = HostLibraryModel.demo(language: language)
        let metrics = ScreenshotDemoConfiguration(scene: .metrics, language: language).makeMetricsModel(hosts: hosts)
        app = AppModel(hosts: hosts, serverMetrics: metrics)
        app.mainWindows.createScene = { [weak self] in self?.requests.append($0) }
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 150, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        return window
    }

    func register(_ model: WindowModel, requestID: UUID? = nil) -> NSWindow {
        let window = makeWindow()
        app.mainWindows.register(window, model: model, requestID: requestID)
        return window
    }

    func close() {
        for window in windows {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        app.shutdownForTermination()
    }
}

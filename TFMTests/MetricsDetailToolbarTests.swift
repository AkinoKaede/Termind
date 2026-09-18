import AppKit
import SwiftData
import SwiftUI
import TermindApplication
import TermindPersistence
import Testing

@testable import Termind

@MainActor
@Suite(.serialized)
struct MetricsDetailToolbarTests {
    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese])
    func compactToolbarSwitchesPagesAndSearchRevealsProcesses(language: AppLanguage) async throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: language)
        let hosts = HostLibraryModel.demo(language: language)
        let model = configuration.makeMetricsModel(hosts: hosts)
        let app = AppModel(hosts: hosts, serverMetrics: model)
        let state = configuration.makeWindow(hosts: hosts)
        let root = RootView(window: state)
            .environment(app)
            .environment(\.locale, language.locale)
            .modelContainer(try TermindPersistence.makeContainer(inMemory: true))
        let window = makeWindow(root)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            app.shutdownForTermination()
        }
        await settle(window)
        let frame = try #require(window.contentView?.superview)
        #expect(state.showsCompactMetricsDetail)
        let picker = try #require(descendants(in: frame, ofType: NSSegmentedControl.self).first)
        #expect(picker.segmentCount == 2)
        #expect(picker.selectedSegment == 0)
        #expect(!picker.visibleRect.isEmpty)
        try capture(frame, name: "\(language.rawValue)-status")

        picker.selectedSegment = 1
        picker.sendAction(picker.action, to: picker.target)
        await settle(window)
        #expect(state.metricsDetailPage == .processes)
        try capture(frame, name: "\(language.rawValue)-processes")
        picker.selectedSegment = 0
        picker.sendAction(picker.action, to: picker.target)
        await settle(window)
        #expect(state.metricsDetailPage == .status)

        state.focusToolbarFind()
        await settle(window)
        #expect(state.metricsDetailPage == .processes)
        #expect(state.isToolbarFindFocused)
        try capture(frame, name: "\(language.rawValue)-search")

        window.setContentSize(CGSize(width: 900, height: 600))
        await settle(window)
        #expect(!state.showsCompactMetricsDetail)
        #expect(descendants(in: frame, ofType: NSSegmentedControl.self).isEmpty)
        window.setContentSize(CGSize(width: 360, height: 600))
        await settle(window)
        #expect(state.metricsDetailPage == .processes)
        #expect(state.showsCompactMetricsDetail)
        let search = try #require(window.toolbar?.items.compactMap { $0 as? NSSearchToolbarItem }.first)
        search.endSearchInteraction()
        await settle(window)
        #expect(!descendants(in: frame, ofType: NSSegmentedControl.self).isEmpty)
    }

    @Test(arguments: [AppLanguage.english, .simplifiedChinese, .traditionalChinese])
    func legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened(_ language: AppLanguage) async throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: language)
        let model = configuration.makeMetricsModel(hosts: .demo())
        let server = try #require(model.servers.first)
        let state = WindowModel()
        state.selectedDestination = .metrics
        state.metricsHostID = server.id
        state.metricsModel = model
        let root = LegacyMetricsToolbarFixture(server: server, model: model)
            .environment(state).environment(\.locale, language.locale)
        let window = makeWindow(root)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
            model.shutdown()
        }
        await settle(window)
        #expect(state.showsCompactMetricsDetail)
        let frame = try #require(window.contentView?.superview)
        #expect(descendants(in: frame, ofType: NSSearchField.self).isEmpty)
        #expect(window.toolbar != nil)
        _ = try #require(state.focusToolbarFindField)
        try await waitUntil(in: window) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
            return window.isKeyWindow
        }
        try capture(frame, name: "legacy-\(language.rawValue)-before-search")
        state.focusToolbarFind()
        let field = try await searchField(in: window, inline: false)
        try capture(frame, name: "legacy-\(language.rawValue)-after-search")
        #expect(state.metricsDetailPage == .processes)
        #expect(field.currentEditor() != nil)
        field.stringValue = "node"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(state.metricsProcessQuery == "node")
        let editor = try #require(field.currentEditor())
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await waitUntil(in: window) { self.searchFields(in: window).isEmpty }
        #expect(!state.isToolbarFindFocused)
        state.focusToolbarFind()
        let reopenedField = try await searchField(in: window, inline: false)
        #expect(reopenedField.stringValue == "node")
        window.setContentSize(CGSize(width: 900, height: 600))
        let expandedField = try await searchField(in: window, inline: true)
        #expect(expandedField.stringValue == "node")
        #expect(state.metricsDetailPage == .processes)
        try capture(frame, name: "legacy-\(language.rawValue)-expanded-search")
        window.setContentSize(CGSize(width: 360, height: 600))
        let compactField = try await searchField(in: window, inline: false)
        #expect(compactField.stringValue == "node")
        #expect(state.metricsDetailPage == .processes)
        #expect(state.isToolbarFindFocused)
    }

    private func makeWindow(_ root: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 360, height: 600),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(CGSize(width: 360, height: 600))
        window.appearance = NSAppearance(named: .aqua)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle(_ window: NSWindow) async {
        window.contentView?.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(350))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func searchField(in window: NSWindow, inline: Bool) async throws -> NSSearchField {
        try await waitUntil(in: window) {
            searchFields(in: window).contains { ($0.window === window) == inline && $0.currentEditor() != nil }
        }
        return try #require(
            searchFields(in: window).first { ($0.window === window) == inline && $0.currentEditor() != nil })
    }

    private func searchFields(in window: NSWindow) -> [NSSearchField] {
        let ownFields =
            window.isVisible
            ? window.contentView.map { descendants(in: $0.superview ?? $0, ofType: NSSearchField.self) } ?? [] : []
        return ownFields.filter { !$0.isHiddenOrHasHiddenAncestor && !$0.visibleRect.isEmpty }
            + (window.childWindows ?? []).flatMap { searchFields(in: $0) }
    }

    private func waitUntil(
        in window: NSWindow, sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(
            condition(), "The toolbar or its popover did not finish updating within two seconds.",
            sourceLocation: sourceLocation)
    }

    private func descendants<T: NSView>(in view: NSView, ofType type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { descendants(in: $0, ofType: type) }
    }

    private func capture(_ view: NSView, name: String) throws {
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "termind-metrics-compact-\(name).png"))
    }
}

/// Like RootView, the toolbar owner observes compact mode so native toolbar
/// preferences are refreshed when the first measured detail width arrives.
private struct LegacyMetricsToolbarFixture: View {
    let server: ServerMetric
    let model: ServerMetricsModel
    @Environment(WindowModel.self) private var window

    var body: some View {
        NavigationStack {
            MetricsDetailView(server: server, model: model)
                .toolbar(removing: window.showsCompactMetricsDetail ? .title : nil)
                .toolbar {
                    ToolbarItem(placement: .principal) { MetricsDetailPagePicker() }
                    ToolbarItem(placement: .primaryAction) { WindowToolbarLegacySearch() }
                }
        }
    }
}

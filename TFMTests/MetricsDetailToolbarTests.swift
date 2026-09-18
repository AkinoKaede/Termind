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

    @Test
    func legacyCompactSearchOpensTheNativeFieldAndKeepsItsQueryWhenWidened() async throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: .english)
        let model = configuration.makeMetricsModel(hosts: .demo())
        let server = try #require(model.servers.first)
        let state = WindowModel()
        state.selectedDestination = .metrics
        state.metricsHostID = server.id
        state.metricsModel = model
        let root = NavigationStack {
            MetricsDetailView(server: server, model: model)
                .toolbar {
                    ToolbarItem(placement: .principal) { MetricsDetailPagePicker() }
                    ToolbarItem(placement: .primaryAction) { WindowToolbarLegacySearch() }
                }
        }.environment(state)
        let window = makeWindow(root)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            model.shutdown()
        }
        await settle(window)
        #expect(state.showsCompactMetricsDetail)
        let frame = try #require(window.contentView?.superview)
        #expect(descendants(in: frame, ofType: NSSearchField.self).isEmpty)
        #expect(window.toolbar != nil)
        _ = try #require(state.focusToolbarFindField)
        try capture(frame, name: "legacy-before-search")
        state.focusToolbarFind()
        await settle(window)
        try capture(frame, name: "legacy-after-search")
        let field = try #require(
            NSApp.windows.filter(\.isVisible).compactMap(\.contentView)
                .flatMap { descendants(in: $0, ofType: NSSearchField.self) }.first)
        #expect(state.metricsDetailPage == .processes)
        #expect(field.currentEditor() != nil)
        field.stringValue = "node"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await settle(window)
        #expect(state.metricsProcessQuery == "node")
        window.setContentSize(CGSize(width: 900, height: 600))
        await settle(window)
        let expandedField = try #require(
            descendants(in: frame, ofType: NSSearchField.self).first)
        #expect(expandedField.stringValue == "node")
        #expect(state.metricsDetailPage == .processes)
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

import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct MetricsInteractionTests {
    @Test
    func toolbarSearchKeepsOverviewAndProcessQueriesIndependent() throws {
        let window = WindowModel()
        window.selectedDestination = .metrics
        #expect(window.findKind == .metrics)
        try #require(window.findContext()).query.wrappedValue = "server"
        window.metricsHostID = UUID()
        #expect(window.findKind == .processes)
        #expect(window.creationActions.isEmpty)
        try #require(window.findContext()).query.wrappedValue = "swift"
        #expect(window.metricsQuery == "server")
        #expect(window.metricsProcessQuery == "swift")
        window.metricsHostID = nil
        #expect(try #require(window.findContext()).query.wrappedValue == "server")
        window.focusToolbarFind()
        #expect(window.isToolbarFindFocused)
    }

    @Test
    func processColumnsSupportAscendingAndDescendingSort() {
        let rows = [
            MetricsProcess(pid: 20, started: 1, name: "zeta", cpu: 30, memory: 200),
            MetricsProcess(pid: 2, started: 1, name: "alpha", cpu: 70, memory: 100),
        ]
        #expect(rows.sorted(using: KeyPathComparator(\.pid)).map(\.pid) == [2, 20])
        #expect(rows.sorted(using: KeyPathComparator(\.name)).map(\.pid) == [2, 20])
        #expect(rows.sorted(using: KeyPathComparator(\.cpuSortValue, order: .reverse)).map(\.pid) == [2, 20])
        #expect(rows.sorted(using: KeyPathComparator(\.memorySortValue, order: .reverse)).map(\.pid) == [20, 2])
    }

    @Test
    func metricsChooserMountsNativeRowsWithTheirRequiredEnvironment() async throws {
        let host = Host(name: "Fixture", host: "fixture.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let windowModel = WindowModel()
        let root = HostChooserView(purpose: .metrics).environment(app).environment(windowModel)
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.close()
            app.shutdownForTermination()
        }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        hosting.layoutSubtreeIfNeeded()
        #expect(hosting.fittingSize.height > 0)
        #expect(windowModel.workspaces.isEmpty)
        #expect(app.serverMetrics.servers.isEmpty)
    }

    @Test
    func processLoadingOccupiesThePanelBeforeCreatingTheTable() async throws {
        let server = ServerMetric(selection: MetricsSelection(id: UUID()), name: "Fixture")
        let hosting = NSHostingView(rootView: MetricsProcessList(server: server).environment(WindowModel()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        func hasTable(_ view: NSView) -> Bool { view is NSTableView || view.subviews.contains(where: hasTable) }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!hasTable(hosting))
        let size = hosting.frame.size
        server.processes = [MetricsProcess(pid: 42, started: 1, name: "worker", cpu: 12, memory: 1024)]
        server.processesDate = Date()
        for _ in 0..<50 {
            hosting.layoutSubtreeIfNeeded()
            if hasTable(hosting) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hasTable(hosting))
        #expect(hosting.frame.size == size)
    }

    @Test
    func statusItemCanBeEnabledDisabledAndOpenItsPopoverWithoutWindowEnvironment() async throws {
        let suite = "MetricsMenuTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let app = AppModel(hosts: HostLibraryModel())
        let menu = MetricsMenuBarController(defaults: defaults)
        defer {
            menu.stop()
            app.shutdownForTermination()
            defaults.removePersistentDomain(forName: suite)
        }
        defaults.set(true, forKey: DesktopSettingsKey.showMetricsInMenuBar)
        menu.start(app.serverMetrics)
        #expect(menu.isVisible)
        // Status-item hosting and popover presentation cross an asynchronous AppKit scene boundary.
        try await Task.sleep(for: .milliseconds(250))
        menu.togglePopover()
        for _ in 0..<100 {
            if menu.isPopoverShown { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(menu.isPopoverShown)
        for _ in 0..<100 {
            if menu.hasNeutralInitialFocus { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(menu.hasNeutralInitialFocus)
        #expect(UserInputModalityTracker.shared.modality == .pointer)
        menu.togglePopover()
        for _ in 0..<100 {
            if !menu.isPopoverShown { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!menu.isPopoverShown)
        defaults.set(false, forKey: DesktopSettingsKey.showMetricsInMenuBar)
        menu.refresh()
        #expect(!menu.isVisible)
        defaults.set(true, forKey: DesktopSettingsKey.showMetricsInMenuBar)
        menu.refresh()
        #expect(menu.isVisible)
    }
}

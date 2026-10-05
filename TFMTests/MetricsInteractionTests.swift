import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct MetricsInteractionTests {
    @Test
    func compactMetricsPagesFollowSearchAndRemainWindowLocal() throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: .english)
        let model = configuration.makeMetricsModel(hosts: .demo())
        defer { model.shutdown() }
        let server = try #require(model.servers.first)
        let window = WindowModel()
        let otherWindow = WindowModel()
        for state in [window, otherWindow] {
            state.selectedDestination = .metrics
            state.metricsModel = model
            state.metricsHostID = server.id
            state.metricsDetailWidth = 360
            #expect(state.showsCompactMetricsDetail)
            #expect(state.metricsDetailPage == .status)
        }

        window.focusToolbarFind()
        #expect(window.metricsDetailPage == .processes)
        #expect(otherWindow.metricsDetailPage == .status)
        try #require(window.findContext()).query.wrappedValue = "node"
        window.isToolbarFindFocused = false
        #expect(window.metricsDetailPage == .processes)
        #expect(window.metricsProcessQuery == "node")

        window.metricsDetailPage = .status
        window.isToolbarFindFocused = true  // Native search activation, including a mouse click.
        #expect(window.metricsDetailPage == .processes)
        window.metricsDetailPage = .status
        window.focusToolbarFind()  // Repeated Command-F while the search is already presented.
        #expect(window.metricsDetailPage == .processes)

        window.metricsDetailWidth = 900
        window.metricsDetailPage = .status
        window.metricsDetailWidth = 700
        #expect(!window.showsCompactMetricsDetail)
        #expect(window.metricsDetailPage == .status)
        window.metricsDetailWidth = 699
        #expect(window.showsCompactMetricsDetail)
        #expect(window.metricsDetailPage == .processes)

        window.isToolbarFindFocused = false
        window.metricsDetailPage = .status
        window.metricsDetailWidth = 900
        window.metricsDetailWidth = 360
        #expect(window.metricsDetailPage == .status)
        window.metricsDetailPage = .processes
        window.metricsHostID = server.id
        #expect(window.metricsDetailPage == .processes)
        window.metricsHostID = UUID()
        #expect(window.metricsDetailPage == .status)
        #expect(!window.showsCompactMetricsDetail)
        window.metricsHostID = nil
        #expect(!window.showsCompactMetricsDetail)
        window.metricsHostID = server.id
        #expect(window.metricsDetailPage == .status)

        server.point = nil
        server.isConnecting = true
        server.journey.fail("Fixture connection failure")
        #expect(server.showsConnectionJourney)
        #expect(!window.showsCompactMetricsDetail)
        window.focusToolbarFind()
        #expect(window.metricsDetailPage == .status)
        window.selectedDestination = .assistant
        #expect(!window.showsCompactMetricsDetail)
    }

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

    @Test(arguments: [HostChooserPurpose.connect, .batchStartup, .metrics])
    func hostChoosersRenderWithTheirRequiredEnvironment(
        purpose: HostChooserPurpose
    ) async throws {
        let host = Host(name: "Fixture", host: "fixture.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let windowModel = WindowModel()
        let root = HostChooserView(purpose: purpose).environment(app).environment(windowModel)
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
    func reopenDefersToSwiftUIOnlyUntilAWindowFactoryExists() {
        var createdWindow = false

        #expect(
            MainWindowCoordinator.handleReopen(
                openExistingWindow: { false },
                createWindow: nil
            ))
        #expect(!createdWindow)

        #expect(
            !MainWindowCoordinator.handleReopen(
                openExistingWindow: { false },
                createWindow: { createdWindow = true }
            ))
        #expect(createdWindow)

        createdWindow = false
        #expect(
            !MainWindowCoordinator.handleReopen(
                openExistingWindow: { true },
                createWindow: { createdWindow = true }
            ))
        #expect(!createdWindow)
    }

    private func hasTable(_ view: NSView) -> Bool {
        view is NSTableView || view.subviews.contains(where: hasTable)
    }
}

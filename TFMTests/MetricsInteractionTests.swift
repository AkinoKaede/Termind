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

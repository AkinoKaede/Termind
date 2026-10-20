// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@MainActor
@Suite(.serialized)
struct ResponsivePageLayoutTests {
    @Test(.requiresVisibleWindow, arguments: ["en", "zh-Hans", "zh-Hant"])
    func vaultEditorsKeepFieldsInsideNarrowColumns(_ language: String) async throws {
        let host = TermindDomain.Host(name: "Production Database Gateway with a Long Name", host: "server.invalid")
        let app = AppModel(hosts: HostLibraryModel(hosts: [host]))
        let navigation = WindowModel()
        defer { app.shutdownForTermination() }
        let editors: [(String, VaultWorkRoute)] = [
            ("host", .hostEditor(host.id)),
            ("group", .hostGroupEditor(groupID: nil, parentID: nil)),
            ("identity", .identityEditor(nil)),
            ("known-host", .knownHostEditor(nil)),
            ("forwarding", .forwardingEditor(nil)),
            ("snippet", .snippetEditor(snippetID: nil, packageID: nil)),
            ("package", .snippetPackageEditor(packageID: nil, parentID: nil)),
            ("generate-key", .generateKey),
        ]
        for (name, route) in editors {
            let controller = NSHostingController(
                rootView: VaultWorkDetailView(route: route).environment(app).environment(navigation)
                    .environment(\.locale, Locale(identifier: language)))
            let window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 320, height: 640),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setContentSize(CGSize(width: 320, height: 640))
            controller.view.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
            window.orderFront(nil)
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.close()
            }
            await layout(controller.view)
            #expect(abs(controller.view.bounds.width - 320) <= 1)
            let scroll = try #require(descendant(in: controller.view, ofType: NSScrollView.self))
            let document = try #require(scroll.documentView)
            #expect(document.frame.width <= scroll.contentView.bounds.width + 1, "\(name) overflows horizontally")
            #expect(scroll.contentInsets.left >= 0 && scroll.contentInsets.right >= 0)
            #expect(!scroll.hasHorizontalScroller)
            let fields = descendants(in: controller.view).compactMap { $0 as? NSTextField }
                .filter { $0.isEditable && !$0.isHiddenOrHasHiddenAncestor }
            #expect(!fields.isEmpty)
            for field in fields {
                let frame = field.convert(field.bounds, to: controller.view)
                #expect(frame.minX >= 0 && frame.maxX <= 321, "\(name): \(frame)")
            }
            let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            let filename = "macos-vault-\(name)-\(language)-320.png"
            Attachment.record(data, named: filename)
            let directory = FileManager.default.temporaryDirectory.appending(path: "termind-vault-ui")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appending(path: filename))
        }
    }

    @Test
    func metricsPagesAndResizeKeepTheProcessTableAndBothScrollPositions() async throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: .english)
        let hosts = HostLibraryModel.demo()
        let model = configuration.makeMetricsModel(hosts: hosts)
        let app = AppModel(hosts: hosts, serverMetrics: model)
        let server = try #require(model.servers.first)
        let state = WindowModel()
        state.selectedDestination = .metrics
        state.metricsModel = model
        state.metricsHostID = server.id
        let hosting = NSHostingView(rootView: MetricsDetailView(server: server).environment(app).environment(state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.close()
            app.shutdownForTermination()
        }
        await layout(hosting)
        let table = try #require(descendant(in: hosting, ofType: NSTableView.self))
        let processScroll = try #require(table.enclosingScrollView)
        let statusScroll = try #require(descendant(in: hosting, ofType: NSScrollView.self))
        #expect(statusScroll !== processScroll)
        let reversedSort = try #require(table.sortDescriptors.first?.reversedSortDescriptor as? NSSortDescriptor)
        table.sortDescriptors = [reversedSort]
        await layout(hosting)
        let sort = table.sortDescriptors
        #expect(sort == [reversedSort])
        processScroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        processScroll.reflectScrolledClipView(processScroll.contentView)
        let wideProcessSize = processScroll.frame.size

        window.setContentSize(CGSize(width: 360, height: 600))
        await layout(hosting)
        #expect(state.showsCompactMetricsDetail)
        #expect(state.metricsDetailPage == .status)
        #expect((statusScroll.documentView?.frame.height ?? 0) > statusScroll.contentView.bounds.height)
        #expect(processScroll.frame.size == wideProcessSize)
        #expect(processScroll.contentView.bounds.minY > 0)
        #expect(descendant(in: hosting, ofType: NSTableView.self) === table)
        #expect(table.sortDescriptors == sort)
        statusScroll.contentView.scroll(to: CGPoint(x: 0, y: 20))
        statusScroll.reflectScrolledClipView(statusScroll.contentView)
        let statusSize = statusScroll.frame.size

        state.metricsDetailPage = .processes
        await layout(hosting)
        #expect(processScroll.frame.height > 480)
        #expect(processScroll.frame.width > 280)
        #expect(statusScroll.frame.size == statusSize)
        #expect(statusScroll.contentView.bounds.minY == 20)
        #expect(processScroll.contentView.bounds.minY > 0)

        for width in [699.0, 700.0, 900.0, 360.0] {
            window.setContentSize(CGSize(width: width, height: 600))
            await layout(hosting)
            #expect(state.showsCompactMetricsDetail == (width < 700))
            #expect(state.metricsDetailPage == .processes)
            #expect(descendant(in: hosting, ofType: NSTableView.self) === table)
            #expect(table.sortDescriptors == sort)
            #expect(processScroll.contentView.bounds.minY > 0)
        }
        state.metricsDetailPage = .status
        await layout(hosting)
        #expect(statusScroll.contentView.bounds.minY == 20)
        state.metricsDetailPage = .processes
        state.metricsProcessQuery = "node"
        await layout(hosting)
        #expect(table.numberOfRows == 2)
        window.setContentSize(CGSize(width: 700, height: 600))
        await layout(hosting)
        #expect(descendant(in: hosting, ofType: NSTableView.self) === table)
        #expect(table.numberOfRows == 2)
        #expect(table.sortDescriptors == sort)
        #expect(state.metricsHostID == server.id)
        #expect(state.metricsProcessQuery == "node")
    }

    @Test
    func vaultResizeKeepsEditorDraftAndParksTheCoveredList() async throws {
        let list = Probe()
        let editor = Probe()
        let host = NSHostingView(rootView: Harness(list: list, editor: editor, showsDetail: true))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        await layout(host)
        let listView = try #require(list.view)
        let editorView = try #require(editor.view)
        editorView.stringValue = "Unsaved host name"
        #expect(abs(editorView.bounds.width - 320) <= 1)
        let listSize = listView.bounds.size

        for width in [360.0, 600.0] {
            host.frame.size.width = width
            await layout(host)
            #expect(editor.view === editorView)
            #expect(editorView.stringValue == "Unsaved host name")
            #expect(abs(editorView.bounds.width - width) <= 1)
            #expect(listView.bounds.size == listSize)
        }

        host.frame.size.width = 601
        await layout(host)
        #expect(editorView.stringValue == "Unsaved host name")
        #expect(abs(editorView.bounds.width - 320) <= 1)
        #expect(abs(listView.bounds.width - 280) <= 1)

        for width in [640.0, 641.0, 681.0, 900.0] {
            host.frame.size.width = width
            await layout(host)
            #expect(abs(editorView.bounds.width - 320) <= 1)
            #expect(abs(listView.bounds.width - (width - 321)) <= 1)
            #expect(editorView.stringValue == "Unsaved host name")
        }

        host.frame.size.width = 360
        await layout(host)
        host.rootView = Harness(list: list, editor: editor, showsDetail: false)
        await layout(host)
        #expect(list.view === listView)
        #expect(abs(listView.bounds.width - 360) <= 1)
        #expect(list.creations == 1)
        #expect(editor.creations == 1)
    }

    @Test(arguments: [360.0, 600.0, 601.0, 900.0])
    func vaultOpeningAndClosingSlideWithoutSqueezingTheEditor(_ width: CGFloat) async throws {
        let list = Probe()
        let editor = Probe()
        let host = NSHostingView(rootView: Harness(list: list, editor: editor, showsDetail: false))
        host.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        await layout(host)
        let editorView = try #require(editor.view)
        let listView = try #require(list.view)
        let editorWidth = editorView.bounds.width
        editorView.stringValue = "Keep this draft"

        for progress in [0.5, 1.0, 0.5, 0.0] {
            host.rootView = Harness(list: list, editor: editor, showsDetail: progress > 0, expansion: progress)
            await layout(host)
            #expect(editor.view === editorView)
            #expect(editorView.bounds.width == editorWidth)
            #expect(editorView.stringValue == "Keep this draft")
            let frame = editorView.convert(editorView.bounds, to: host)
            if progress == 0.5 {
                #expect(frame.minX > width - editorWidth && frame.minX < width)
                if width >= 601 {
                    #expect(abs(listView.bounds.width - (width - 321 * progress)) <= 1)
                }
            } else if progress == 1 {
                #expect(abs(frame.maxX - width) <= 1)
            } else {
                #expect(abs(frame.minX - width) <= 1)
                #expect(abs(listView.bounds.width - width) <= 1)
            }
        }
        #expect(list.creations == 1 && editor.creations == 1)
    }

    private func layout(_ view: NSView) async {
        view.layoutSubtreeIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        try? await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
    }

    private func descendant<T: NSView>(in view: NSView, ofType type: T.Type) -> T? {
        if let result = view as? T { return result }
        return view.subviews.lazy.compactMap { descendant(in: $0, ofType: type) }.first
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private final class Probe {
        var view: NSTextField?
        var creations = 0
    }

    private struct ProbeView: NSViewRepresentable {
        let probe: Probe

        func makeNSView(context: Context) -> NSTextField {
            let view = NSTextField()
            probe.view = view
            probe.creations += 1
            return view
        }

        func updateNSView(_ view: NSTextField, context: Context) {}
    }

    private struct Harness: View {
        let list: Probe
        let editor: Probe
        let showsDetail: Bool
        var expansion: CGFloat? = nil

        var body: some View {
            var layout = VaultWorkspaceLayout(showsDetail: showsDetail)
            if let expansion { layout.animatableData = expansion }
            return layout {
                ProbeView(probe: list).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ProbeView(probe: editor).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

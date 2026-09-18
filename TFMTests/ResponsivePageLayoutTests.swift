import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@MainActor
@Suite(.serialized)
struct ResponsivePageLayoutTests {
    @Test
    func metricsResizeKeepsTheProcessTableAndMakesAllDetailsScrollable() async throws {
        let configuration = ScreenshotDemoConfiguration(scene: .metricsDetail, language: .english)
        let model = configuration.makeMetricsModel(hosts: .demo())
        let server = try #require(model.servers.first)
        let state = WindowModel()
        state.metricsHostID = server.id
        let hosting = NSHostingView(rootView: MetricsDetailView(server: server, model: model).environment(state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer {
            window.close()
            model.shutdown()
        }
        await layout(hosting)
        let table = try #require(descendant(in: hosting, ofType: NSTableView.self))
        let processScroll = try #require(table.enclosingScrollView)
        let reversedSort = try #require(table.sortDescriptors.first?.reversedSortDescriptor as? NSSortDescriptor)
        table.sortDescriptors = [reversedSort]
        await layout(hosting)
        let sort = table.sortDescriptors
        #expect(sort == [reversedSort])
        processScroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        processScroll.reflectScrolledClipView(processScroll.contentView)

        window.setContentSize(CGSize(width: 360, height: 600))
        await layout(hosting)
        let outerScroll = try #require(descendant(in: hosting, ofType: NSScrollView.self))
        #expect(outerScroll !== processScroll)
        #expect((outerScroll.documentView?.frame.height ?? 0) > outerScroll.contentView.bounds.height)
        #expect(processScroll.frame.height > 200)
        #expect(processScroll.contentView.bounds.minY > 0)
        #expect(descendant(in: hosting, ofType: NSTableView.self) === table)
        #expect(table.sortDescriptors == sort)

        state.metricsProcessQuery = "node"
        await layout(hosting)
        #expect(table.numberOfRows == 2)
        window.setContentSize(CGSize(width: 630, height: 600))
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
        let listSize = listView.bounds.size

        host.frame.size.width = 360
        await layout(host)
        #expect(editor.view === editorView)
        #expect(editorView.stringValue == "Unsaved host name")
        #expect(abs(editorView.bounds.width - 360) <= 1)
        #expect(listView.bounds.size == listSize)

        host.frame.size.width = 721
        await layout(host)
        #expect(editorView.stringValue == "Unsaved host name")
        #expect(abs(editorView.bounds.width - 360) <= 1)
        #expect(abs(listView.bounds.width - 360) <= 1)

        host.frame.size.width = 360
        await layout(host)
        host.rootView = Harness(list: list, editor: editor, showsDetail: false)
        await layout(host)
        #expect(list.view === listView)
        #expect(abs(listView.bounds.width - 360) <= 1)
        #expect(list.creations == 1)
        #expect(editor.creations == 1)
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

        var body: some View {
            VaultWorkspaceLayout(showsDetail: showsDetail) {
                ProbeView(probe: list).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ProbeView(probe: editor).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

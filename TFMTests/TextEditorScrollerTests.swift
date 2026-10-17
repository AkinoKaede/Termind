import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct TextEditorScrollerTests {
    @Test
    func snippetScriptHidesItsUnusedScrollerAsTheFormGrows() async throws {
        let state = ScriptState()
        let fixture = Fixture(
            Form {
                SnippetScriptSection(script: Binding(get: { state.text }, set: { state.text = $0 }), minHeight: 180) {
                    Text("Assessment")
                }
            }
            .formStyle(.grouped))
        defer { fixture.window.close() }
        await fixture.layout()
        let scroll = try #require(fixture.editorScrollViews.first)
        scroll.scrollerStyle = .legacy

        for text in ["", "echo hello", Array(repeating: "echo hello", count: 80).joined(separator: "\n"), ""] {
            state.text = text
            await fixture.layout()
            let editor = try #require(scroll.documentView as? NSTextView)
            #expect(editor.string == text)
            #expect(scroll.autohidesScrollers)
            let overflows = editor.bounds.height > scroll.contentSize.height + 1
            #expect(scroll.verticalScroller?.isHidden == !overflows)
        }
        #expect(!fixture.window.isVisible)
    }

    @Test
    func keyImportHidesUnusedScrollersInAllThreeFields() async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let fixture = Fixture(
            KeychainImportDetail()
                .environment(app)
                .environment(WindowModel(workspaces: []))
                .environment(VaultWorkEditingSession()))
        defer {
            fixture.window.close()
            app.shutdownForTermination()
        }
        await fixture.layout()
        let scrollViews = fixture.editorScrollViews
        #expect(scrollViews.count == 3)
        for scroll in scrollViews { scroll.scrollerStyle = .legacy }
        await fixture.layout()
        for scroll in scrollViews {
            #expect((scroll.documentView as? NSTextView)?.string.isEmpty == true)
            #expect(scroll.autohidesScrollers)
            #expect(scroll.verticalScroller?.isHidden == true)
        }
        #expect(!fixture.window.isVisible)
    }

    @Observable final class ScriptState {
        var text = ""
    }

    private final class Fixture {
        let view: NSHostingView<AnyView>
        let window: NSWindow

        init(_ content: some View) {
            view = NSHostingView(rootView: AnyView(content))
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 900),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
        }

        func layout() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            view.layoutSubtreeIfNeeded()
        }

        var editorScrollViews: [NSScrollView] {
            func find(in root: NSView) -> [NSScrollView] {
                if let scroll = root as? NSScrollView, scroll.documentView is NSTextView { return [scroll] }
                return root.subviews.flatMap { find(in: $0) }
            }
            return find(in: view)
        }
    }
}

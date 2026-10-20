// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import TermindDomain
import Testing

@testable import Termind
@testable import TermindPresentation

@Suite(.serialized) @MainActor
struct TextEditorScrollerTests {
    @Test
    func cachedTargetRecoversAfterReplacementAndReparenting() {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: frame)
        window.contentView = root
        func editor(in parent: NSView) -> NSScrollView {
            let scroll = NSScrollView(frame: frame)
            scroll.documentView = NSTextView(frame: frame)
            scroll.autohidesScrollers = false
            parent.addSubview(scroll)
            return scroll
        }
        let first = editor(in: root)
        let resolver = TextEditorScrollViewConfigurator.ResolverView(frame: frame)
        root.addSubview(resolver)
        resolver.configureScrollView()
        #expect(first.autohidesScrollers)

        first.removeFromSuperview()
        let replacement = editor(in: root)
        resolver.configureScrollView()
        #expect(replacement.autohidesScrollers)

        let otherRoot = NSView(frame: frame)
        let otherWindow = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        otherWindow.contentView = otherRoot
        let movedTarget = editor(in: otherRoot)
        replacement.autohidesScrollers = false
        resolver.removeFromSuperview()
        otherRoot.addSubview(resolver)
        resolver.configureScrollView()
        #expect(movedTarget.autohidesScrollers)
        #expect(!replacement.autohidesScrollers)
        #expect(!window.isVisible && !otherWindow.isVisible)
    }

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

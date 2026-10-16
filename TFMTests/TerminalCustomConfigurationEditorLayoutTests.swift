import AppKit
import GhosttyTerminal
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct TerminalCustomConfigurationEditorLayoutTests {
    @Test(arguments: [CGFloat(650), CGFloat(1000)])
    func nameFieldLeavesRoomForItsNativeFocusRing(width: CGFloat) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.window.setContentSize(CGSize(width: width, height: 800))
        await fixture.layout()
        let field = try #require(fixture.descendant(NSTextField.self))
        let scroll = try #require(field.enclosingScrollView)
        let focusFrame = field.convert(field.bounds.insetBy(dx: -3, dy: -3), to: scroll.contentView)
        #expect(scroll.contentView.bounds.contains(focusFrame))
    }

    @Test func discardedDraftCannotBeSavedByThePendingAutosaveTask() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        await fixture.layout()
        fixture.draft.value.configuration = "background = 123456"
        fixture.model.deleteCustomTheme(id: fixture.draft.id)
        fixture.navigation.clearTerminalThemeEditor()
        await fixture.layout()
        #expect(fixture.model.themeLibrary.themes.isEmpty)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func editorAndPreviewFillThePageRegardlessOfTextLength(language: String, isDark: Bool) async throws {
        let fixture = Fixture(language: language, isDark: isDark)
        defer { fixture.close() }
        await fixture.layout()
        let editor = try #require(fixture.descendant(NSTextView.self))
        let scroll = try #require(editor.enclosingScrollView)
        let preview = try #require(fixture.descendant(AppTerminalView.self))
        let editorHeight = scroll.bounds.height
        let previewHeight = preview.bounds.height
        #expect(editorHeight > 400)

        for text in ["", "background = 152033", Self.longConfiguration, ""] {
            var updated = fixture.draft.value
            updated.configuration = text
            fixture.model.saveCustomTheme(updated, isNew: false)
            await fixture.layout()
            #expect(editor.string == text)
            #expect(abs(scroll.bounds.height - editorHeight) <= 1)
            #expect(abs(preview.bounds.height - previewHeight) <= 1)
            fixture.expectFillsPage(editor: scroll, preview: preview)
            if text == Self.longConfiguration {
                #expect(editor.bounds.height > scroll.contentSize.height)
                editor.scrollRangeToVisible(NSRange(location: (text as NSString).length, length: 0))
                #expect(scroll.contentView.bounds.minY > 0)
                #expect(abs(scroll.bounds.height - editorHeight) <= 1)
            }
        }
        #expect(!fixture.window.isVisible)
    }

    @Test
    func resizingPreservesTheEditorSelectionAndPreviewWhileChangingLayout() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        await fixture.layout()
        let editor = try #require(fixture.descendant(NSTextView.self))
        let scroll = try #require(editor.enclosingScrollView)
        let preview = try #require(fixture.descendant(AppTerminalView.self))
        let previewController = preview.controller
        editor.insertText(Self.longConfiguration, replacementRange: NSRange(location: 0, length: 0))
        await fixture.layout()
        let selection = NSRange(location: 4, length: 8)
        editor.setSelectedRange(selection)
        editor.scrollRangeToVisible(selection)

        for size in [
            CGSize(width: 1000, height: 1000),
            CGSize(width: 1000, height: 620),
            CGSize(width: 650, height: 620),
            CGSize(width: 1000, height: 800),
        ] {
            fixture.window.setContentSize(size)
            await fixture.layout()
            #expect(fixture.descendant(NSTextView.self) === editor)
            #expect(fixture.descendant(AppTerminalView.self) === preview)
            #expect(preview.controller === previewController)
            #expect(editor.string == Self.longConfiguration)
            #expect(editor.selectedRange() == selection)
            if size.width >= 700 {
                fixture.expectFillsPage(editor: scroll, preview: preview)
            } else {
                #expect(abs(scroll.bounds.height - 360) <= 1)
                let pageScroll = try #require(scroll.superview?.enclosingScrollView)
                let document = try #require(pageScroll.documentView)
                #expect(document.bounds.height > pageScroll.contentSize.height)
                let editorFrame = scroll.convert(scroll.bounds, to: fixture.view)
                let previewFrame = preview.convert(preview.bounds, to: fixture.view)
                #expect(abs(editorFrame.minX - previewFrame.minX) <= 1)
            }
        }
        #expect(fixture.draft.value.configuration == Self.longConfiguration)
        #expect(fixture.model.themeLibrary.themes.first?.configuration == Self.longConfiguration)
        #expect(!fixture.window.isVisible)
    }

    @Test
    func accessibilityTextKeepsTheStackedEditorScrollableAtWideWidths() async throws {
        let fixture = Fixture(typeSize: .accessibility1)
        defer { fixture.close() }
        fixture.window.setContentSize(CGSize(width: 1000, height: 620))
        await fixture.layout()
        let editor = try #require(fixture.descendant(NSTextView.self))
        let scroll = try #require(editor.enclosingScrollView)
        let preview = try #require(fixture.descendant(AppTerminalView.self))
        #expect(abs(scroll.bounds.height - 360) <= 1)
        let editorFrame = scroll.convert(scroll.bounds, to: fixture.view)
        let previewFrame = preview.convert(preview.bounds, to: fixture.view)
        #expect(abs(editorFrame.minX - previewFrame.minX) <= 1)
        let pageScroll = try #require(scroll.superview?.enclosingScrollView)
        let document = try #require(pageScroll.documentView)
        #expect(document.bounds.height > pageScroll.contentSize.height)
        #expect(!fixture.window.isVisible)
    }

    private static var longConfiguration: String {
        (["background = 152033"] + (0..<160).map { "# Configuration line \($0)" }).joined(separator: "\n")
    }

    private final class Fixture {
        let model = TerminalSettingsModel()
        let app: AppModel
        let navigation = WindowModel(workspaces: [])
        let draft: TerminalCustomThemeDraft
        let controller: NSHostingController<AnyView>
        let window: NSWindow
        var view: NSView { controller.view }

        init(language: String = "en", isDark: Bool = true, typeSize: DynamicTypeSize = .large) {
            let theme = TerminalCustomTheme(
                name: "Layout", appearance: isDark ? .dark : .light,
                baseThemeName: isDark ? "Termind Dark" : "Termind Light")
            model.saveCustomTheme(theme, isNew: true)
            draft = .init(theme, isNew: false)
            app = AppModel(hosts: HostLibraryModel(), terminalSettings: model)
            navigation.openSettings(route: .terminalCustomThemes)
            navigation.terminalThemeDraft = draft
            navigation.settingsRoute = .terminalCustomTheme(theme.id)
            controller = NSHostingController(
                rootView: AnyView(
                    TerminalCustomConfigurationEditorPage(draft: draft, model: model)
                        .environment(app)
                        .environment(navigation)
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, isDark ? .dark : .light)
                        .environment(\.dynamicTypeSize, typeSize)))
            controller.sizingOptions = []
            window = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1000, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
            window.contentViewController = controller
            window.setContentSize(CGSize(width: 1000, height: 800))
            controller.view.frame = CGRect(x: 0, y: 0, width: 1000, height: 800)
        }

        func layout() async {
            view.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(350))
            view.layoutSubtreeIfNeeded()
        }

        func descendant<T: NSView>(_ type: T.Type) -> T? {
            func find(in view: NSView) -> T? {
                if let result = view as? T { return result }
                return view.subviews.lazy.compactMap { find(in: $0) }.first
            }
            return find(in: view)
        }

        func expectFillsPage(editor: NSScrollView, preview: AppTerminalView) {
            let editorFrame = editor.convert(editor.bounds, to: view)
            let previewFrame = preview.convert(preview.bounds, to: view)
            let editorBottom = view.isFlipped ? view.bounds.maxY - editorFrame.maxY : editorFrame.minY
            let previewBottom = view.isFlipped ? view.bounds.maxY - previewFrame.maxY : previewFrame.minY
            #expect(abs(editorBottom - 16) <= 1)
            // The terminal and color specimens share one panel; specimens sit below the native surface.
            #expect(previewBottom > editorBottom)
            #expect(previewFrame.height >= 220)
            let editorTop = view.isFlipped ? editorFrame.minY : editorFrame.maxY
            let previewTop = view.isFlipped ? previewFrame.minY : previewFrame.maxY
            #expect(abs(editorTop - previewTop) <= 1)
            #expect(previewFrame.minX > editorFrame.maxX)
        }

        func close() {
            window.contentViewController = nil
            window.close()
            app.shutdownForTermination()
        }
    }
}

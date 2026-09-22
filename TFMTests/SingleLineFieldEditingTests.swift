import AppKit
import SwiftUI
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

@Suite("Native single-line field editing", .serialized)
@MainActor
struct SingleLineFieldEditingTests {
    @Test func nativeEditorKeepsTheCaretAndDefersMarkedTextNormalization() throws {
        let field = NSTextField()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        defer { window.close() }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        field.stringValue = "中文\r\n\nName"
        editor.string = field.stringValue
        editor.setSelectedRange(NSRange(location: 5, length: 0))
        #expect(SingleLineFieldEditing.normalizedValue(in: field) == "中文 Name")
        #expect(editor.string == "中文 Name")
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
        #expect(window.firstResponder === editor)
        editor.setMarkedText(
            "拼音", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
        #expect(editor.hasMarkedText())
        let composing = editor.string
        #expect(SingleLineFieldEditing.normalizedValue(in: field) == nil)
        #expect(editor.string == composing)
        editor.unmarkText()
        #expect(SingleLineFieldEditing.normalizedValue(in: field) == editor.string)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func hostFormKeepsPastedAndTypedTextSingleLine(language: String) async throws {
        let draft = SingleLineHostTestDraft()
        let hosting = NSHostingView(
            rootView: SingleLineHostTestForm(draft: draft).environment(\.locale, Locale(identifier: language)))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: .borderless,
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(findEditableField(in: hosting, value: "fixture.invalid"))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        SingleLineFieldEditing.insert("first.example\r\n\nsecond.example", into: editor)
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.host.host == "first.example second.example")
        #expect(!field.stringValue.contains(where: { $0.isNewline }))
        #expect(window.firstResponder === editor)
        editor.selectAll(nil)
        editor.insertText("2001:db8::1", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.host.host == "2001:db8::1")
        editor.doCommand(by: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!draft.host.host.contains(where: { $0.isNewline }))
        #expect(!field.stringValue.contains(where: { $0.isNewline }))
        let originalHeight = field.frame.height
        let longAddress = String(repeating: "long-host-", count: 80) + ".invalid"
        editor.selectAll(nil)
        SingleLineFieldEditing.insert(longAddress, into: editor)
        try await Task.sleep(for: .milliseconds(100))
        #expect(draft.host.host == longAddress)
        #expect(field.frame.height == originalHeight)
    }

    private func findEditableField(in view: NSView, value: String) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.stringValue == value { return field }
        return view.subviews.lazy.compactMap { findEditableField(in: $0, value: value) }.first
    }

    @Test func normalizesTheNativeFieldWithoutAnActiveEditor() {
        let field = NSTextField()
        field.stringValue = "中文\r\n\n名称"
        #expect(SingleLineFieldEditing.normalizedValue(in: field) == "中文 名称")
        #expect(field.stringValue == "中文 名称")
    }

    @Test func renameCoordinatorWritesTheSameNormalizedValueAsTheField() {
        var text = "Original"
        var submitted = false
        var cancelled = false
        let coordinator = SidebarInlineRenameField.Coordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            onSubmit: { submitted = true }, onCancel: { cancelled = true }
        )
        let field = NSTextField()
        field.stringValue = "New\u{2028}Name"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(text == "New Name")
        #expect(field.stringValue == text)
        #expect(!submitted)
        #expect(!cancelled)
    }
}

@Observable
@MainActor
private final class SingleLineHostTestDraft {
    var host = TermindDomain.Host(name: "Fixture", host: "fixture.invalid")
}

private struct SingleLineHostTestForm: View {
    @Bindable var draft: SingleLineHostTestDraft

    var body: some View {
        Form {
            HostOrganizationSection(host: $draft.host) {
                EmptyView()
            } tagsField: {
                EmptyView()
            }
            HostConnectionFields(host: $draft.host)
        }
        .formStyle(.grouped)
    }
}

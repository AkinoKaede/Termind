// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@Suite @MainActor
struct MessageEditorShortcutTests {
    @Test(arguments: InputSendShortcut.allCases)
    func editUsesTheSelectedSendShortcutAndInsertsTheOtherAtTheSelection(shortcut: InputSendShortcut) throws {
        let editor = NativeEditorTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 160))
        editor.isRichText = false
        editor.string = "before after"
        editor.sendShortcut = { shortcut }
        var submitted: [String] = []
        editor.commit = { submitted.append(editor.string) }
        func event(command: Bool, repeated: Bool = false) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: command ? .command : [],
                    timestamp: 0, windowNumber: 0, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: repeated, keyCode: 36))
        }
        editor.setSelectedRange(NSRange(location: 6, length: 1))
        editor.keyDown(with: try event(command: shortcut == .returnKey))
        #expect(editor.string == "before\nafter")
        #expect(submitted.isEmpty)
        editor.keyDown(with: try event(command: shortcut == .commandReturn))
        #expect(submitted == ["before\nafter"])
        editor.keyDown(with: try event(command: shortcut == .commandReturn, repeated: true))
        #expect(submitted.count == 1)
        editor.setMarkedText(
            "input", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        editor.keyDown(with: try event(command: shortcut == .commandReturn))
        #expect(submitted.count == 1)
    }
}

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct MessageComposerShortcutFocusTests {
    @Test(arguments: InputSendShortcut.allCases)
    func composerUsesThePreferenceAtTheCaretWithoutSubmittingComposition(shortcut: InputSendShortcut) async throws {
        let suite = "MessageComposerShortcutFocusTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(shortcut.rawValue, forKey: SettingsKey.inputSendShortcut)
        let app = AppModel(hosts: HostLibraryModel())
        let navigation = WindowModel()
        let conversation = ConversationModel()
        conversation.composer.draft = "before after"
        var submitted: [String] = []
        let controller = NSHostingController(
            rootView: ComposerView(
                conversation: conversation,
                onSend: {
                    submitted.append(conversation.composer.draft)
                    conversation.composer.draft = ""
                }
            ).environment(app).environment(navigation).defaultAppStorage(defaults))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 650, height: 200),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer {
            window.close()
            defaults.removePersistentDomain(forName: suite)
            app.shutdownForTermination()
        }
        func settle() async {
            try? await Task.sleep(for: .milliseconds(100))
            controller.view.layoutSubtreeIfNeeded()
        }
        func find(_ view: NSView) -> NSTextView? {
            if let editor = view as? NSTextView { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        await settle()
        for _ in 0..<30 where !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            await settle()
        }
        try #require(window.isKeyWindow)
        let editor = try #require(find(controller.view))
        #expect(window.makeFirstResponder(editor))
        await settle()
        editor.setSelectedRange(NSRange(location: 6, length: 1))
        func pressReturn(command: Bool, shift: Bool = false) throws {
            var modifiers: NSEvent.ModifierFlags = command ? .command : []
            if shift { modifiers.insert(.shift) }
            NSApp.sendEvent(
                try #require(
                    NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                    )))
        }
        try pressReturn(command: shortcut == .returnKey)
        await settle()
        #expect(conversation.composer.draft == "before\nafter")
        #expect(editor.string == conversation.composer.draft)
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        #expect(submitted.isEmpty)
        let undoManager = try #require(editor.undoManager)
        #expect(undoManager.canUndo)
        undoManager.undo()
        await settle()
        #expect(conversation.composer.draft == "before after")
        undoManager.redo()
        await settle()
        #expect(conversation.composer.draft == "before\nafter")
        let initialHeight = try #require(editor.enclosingScrollView).frame.height
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        try pressReturn(command: shortcut == .returnKey)
        await settle()
        try pressReturn(command: false, shift: true)
        await settle()
        #expect(conversation.composer.draft == "before\nafter\n\n")
        #expect(editor.selectedRange() == NSRange(location: 14, length: 0))
        #expect(try #require(editor.enclosingScrollView).frame.height > initialHeight)
        #expect(submitted.isEmpty)
        try pressReturn(command: shortcut == .commandReturn)
        await settle()
        #expect(submitted == ["before\nafter\n\n"])
        #expect(window.firstResponder === editor)
        conversation.composer.draft = "composition"
        await settle()
        editor.setMarkedText(
            "input", selectedRange: NSRange(location: 5, length: 0), replacementRange: editor.selectedRange())
        try pressReturn(command: shortcut == .commandReturn)
        #expect(submitted.count == 1)
        editor.unmarkText()
        let next: InputSendShortcut = shortcut == .returnKey ? .commandReturn : .returnKey
        defaults.set(next.rawValue, forKey: SettingsKey.inputSendShortcut)
        await settle()
        #expect(find(controller.view) === editor)
        conversation.composer.draft = "new shortcut"
        await settle()
        try pressReturn(command: next == .commandReturn)
        await settle()
        #expect(submitted.last == "new shortcut" && submitted.count == 2)
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication
import Testing

@testable import Termind

@Suite @MainActor
struct ComposerBackspaceTests {
    @Test
    func unmountedObserverDoesNotConsumeBackspace() throws {
        let observer = TextViewMarkedTextObserver.ObserverView()
        var calls = 0
        observer.emptyBackspace = {
            calls += 1
            return true
        }
        #expect(!observer.consumeEmptyBackspace(try backspace(windowNumber: 0)))
        #expect(calls == 0)
    }

    @Test
    func emptyEditorRoutesBackspaceWithoutPresentingAWindow() throws {
        let window = ComposerKeyStateWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        try verifyBackspace(in: window)
    }

    @Test(.requiresVisibleWindow)
    func onlyEmptyFocusedUnmarkedEditorDismissesSelections() async throws {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        for _ in 0..<100 where !window.isKeyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            window.isKeyWindow,
            "active=\(NSApp.isActive), canBecomeKey=\(window.canBecomeKey), keyWindow=\(String(describing: NSApp.keyWindow))"
        )
        try verifyBackspace(in: window)
    }

    private func verifyBackspace(in window: NSWindow) throws {
        let editor = NSTextView(frame: try #require(window.contentView).bounds)
        let observer = TextViewMarkedTextObserver.ObserverView()
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(observer)
        defer { observer.stop() }
        try #require(window.makeFirstResponder(editor))
        let event = try backspace(windowNumber: window.windowNumber)
        let conversation = ConversationModel()
        conversation.isPlanning = true
        conversation.composer.armedSkillName = "disk-triage"
        var composerFocused = true
        observer.emptyBackspace = {
            composerFocused && conversation.dismissLastComposerSelectionIfDraftEmpty()
        }
        if let controlledWindow = window as? ComposerKeyStateWindow {
            controlledWindow.acceptsKeyboardEvents = false
            #expect(!observer.consumeEmptyBackspace(event))
            controlledWindow.acceptsKeyboardEvents = true
        }

        for modifiers: NSEvent.ModifierFlags in [.command, .option, .control, .shift, .function] {
            #expect(
                !observer.consumeEmptyBackspace(try backspace(windowNumber: window.windowNumber, modifiers: modifiers)))
        }
        #expect(!observer.consumeEmptyBackspace(try backspace(windowNumber: window.windowNumber, keyCode: 117)))
        #expect(!observer.consumeEmptyBackspace(try backspace(windowNumber: window.windowNumber, type: .keyUp)))
        editor.string = "x"
        editor.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(!observer.consumeEmptyBackspace(event))
        editor.deleteBackward(nil)
        #expect(editor.string.isEmpty)
        #expect(conversation.composer.armedSkillName == "disk-triage")

        editor.setMarkedText(
            "a", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!observer.consumeEmptyBackspace(event))
        editor.unmarkText()
        editor.string = ""
        editor.isEditable = false
        #expect(!observer.consumeEmptyBackspace(event))
        editor.isEditable = true
        try #require(window.makeFirstResponder(nil))
        #expect(!observer.consumeEmptyBackspace(event))
        try #require(window.makeFirstResponder(editor))
        composerFocused = false
        #expect(!observer.consumeEmptyBackspace(event))
        composerFocused = true

        #expect(observer.consumeEmptyBackspace(event))
        #expect(conversation.composer.armedSkillName == nil)
        #expect(conversation.isPlanning)
        #expect(observer.consumeEmptyBackspace(event))
        #expect(!conversation.isPlanning)
        #expect(!observer.consumeEmptyBackspace(event))
        #expect(window.firstResponder === editor)
    }

    private func backspace(
        windowNumber: Int, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 51,
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
                context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
                isARepeat: false, keyCode: keyCode))
    }
}

/// Exercises native editing and event routing without taking focus from the user's app.
@MainActor
private final class ComposerKeyStateWindow: NSWindow {
    var acceptsKeyboardEvents = true
    override var isKeyWindow: Bool { acceptsKeyboardEvents }
}

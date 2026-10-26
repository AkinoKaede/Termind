// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import SwiftUI
import TermindApplication

struct TerminalInputEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var hasMarkedText: Bool
    let isActive: Bool
    let focusRequest: UInt64
    let accessibilityLabel: String
    let sendShortcut: InputSendShortcut
    let focusChanged: (Bool) -> Void
    let submit: () -> Void
    let generate: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TerminalInputScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = TerminalInputTextView()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        scroll.documentView = editor
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? TerminalInputTextView else { return }
        context.coordinator.parent = self
        editor.acceptsSubmission = isActive
        editor.sendShortcut = sendShortcut
        editor.submit = submit
        editor.generate = generate
        editor.focusChanged = focusChanged
        editor.markedTextChanged = { hasMarkedText = $0 }
        editor.setAccessibilityLabel(accessibilityLabel)
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            editor.scrollRangeToVisible(editor.selectedRange())
        }
        let previousRequest = editor.focusRequest
        editor.focusRequest = focusRequest
        if previousRequest != focusRequest, isActive {
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.acceptsSubmission, editor.focusRequest == focusRequest,
                    let window = editor.window, window.isKeyWindow
                else { return }
                window.makeFirstResponder(editor)
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let editor = scroll.documentView as? TerminalInputTextView else { return }
        editor.acceptsSubmission = false
        editor.submit = {}
        editor.generate = {}
        editor.focusChanged = { _ in }
        editor.markedTextChanged = { _ in }
        editor.delegate = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TerminalInputEditor
        init(_ parent: TerminalInputEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.hasMarkedText = editor.hasMarkedText()
            parent.text = editor.string
        }
    }
}

private final class TerminalInputScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard let editor = documentView as? NSTextView else { return }
        // Empty space must still belong to the editable document, not to an
        // unclickable clip view beneath a one-line NSTextView.
        editor.minSize = NSSize(width: 0, height: contentSize.height)
        if editor.frame.height < contentSize.height {
            editor.setFrameSize(NSSize(width: contentSize.width, height: contentSize.height))
        }
    }
}

final class TerminalInputTextView: NSTextView {
    var acceptsSubmission = false
    var focusRequest: UInt64 = 0
    var sendShortcut: InputSendShortcut = .returnKey
    var submit: () -> Void = {}
    var generate: () -> Void = {}
    var focusChanged: (Bool) -> Void = { _ in }
    var markedTextChanged: (Bool) -> Void = { _ in }

    static func isGenerateKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .control, .option])
        return event.charactersIgnoringModifiers?.lowercased() == "i" && modifiers == .command
    }

    /// Consume the menu action even for an empty draft or ongoing composition:
    /// it must never fall back to reading the shell behind the focused editor.
    static func generateInFocusedEditor(in window: NSWindow?) -> Bool {
        guard let editor = window?.firstResponder as? TerminalInputTextView, editor.ownsInputActions else {
            return false
        }
        if !editor.hasMarkedText() { editor.generate() }
        return true
    }

    private var ownsInputActions: Bool {
        acceptsSubmission && window?.isKeyWindow == true && window?.firstResponder === self
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsInputActions else { return super.performKeyEquivalent(with: event) }
        if Self.isGenerateKey(event) {
            if !event.isARepeat, !hasMarkedText() { generate() }
            return true
        }
        if event.modifierFlags.contains(.command), handleReturn(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if ownsInputActions, handleReturn(event) { return }
        super.keyDown(with: event)
    }

    private func handleReturn(_ event: NSEvent) -> Bool {
        switch sendShortcut.action(for: event, hasMarkedText: hasMarkedText()) {
        case .submit:
            if !event.isARepeat { submit() }
            return true
        case .newline:
            insertNewline(nil)
            return true
        case .system:
            return false
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { focusChanged(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted {
            // Wait until AppKit has installed the next responder before SwiftUI
            // reconciles the terminal's focus request.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.focusChanged(false)
            }
        }
        return accepted
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        markedTextChanged(hasMarkedText())
    }

    override func unmarkText() {
        super.unmarkText()
        markedTextChanged(false)
    }
}

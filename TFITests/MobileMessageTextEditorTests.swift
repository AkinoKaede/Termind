// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileMessageTextEditorTests {
    @Test
    func unfocusedOrUnmountedEditorsCannotSubmit() {
        let editor = MobileMessageTextView()
        var submissions = 0
        editor.submit = { submissions += 1 }
        editor.sendShortcut = .commandReturn
        let command = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(editor.handleReturn(_:)))
        editor.handleReturn(command)
        #expect(submissions == 0)
        #expect(!editor.canPerformAction(#selector(MobileMessageTextView.handleReturn(_:)), withSender: command))
        #expect(editor.textView(editor, shouldChangeTextIn: NSRange(location: 0, length: 0), replacementText: "\n"))
    }

    @Test(.requiresKeyWindow, arguments: InputSendShortcut.allCases)
    func keyboardAndSoftwareReturnUseThePreferenceWithoutSendingMarkedOrPastedText(shortcut: InputSendShortcut)
        async throws
    {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        let editor = MobileMessageTextView()
        controller.view = editor
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            editor.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(100))
        try #require(editor.becomeFirstResponder())
        editor.sendShortcut = shortcut
        editor.text = "before after"
        editor.selectedRange = NSRange(location: 6, length: 1)
        var submissions: [String] = []
        editor.submit = { submissions.append(editor.text) }
        let command = UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(editor.handleReturn(_:)))
        if shortcut == .returnKey {
            editor.handleReturn(command)
        } else {
            editor.insertText("\n")
        }
        #expect(editor.text == "before\nafter")
        #expect(submissions.isEmpty)
        if shortcut == .commandReturn {
            editor.handleReturn(command)
        } else {
            editor.insertText("\n")
        }
        #expect(submissions == ["before\nafter"])
        #expect(editor.isFirstResponder)
        #expect(editor.textView(editor, shouldChangeTextIn: editor.selectedRange, replacementText: "a\nb"))
        editor.insertLiteralNewline()
        #expect(submissions.count == 1)
        editor.setMarkedText("输入", selectedRange: NSRange(location: 2, length: 0))
        editor.handleReturn(command)
        #expect(submissions.count == 1)
        #expect(!editor.canPerformAction(#selector(MobileMessageTextView.handleReturn(_:)), withSender: command))
        #expect(editor.textView(editor, shouldChangeTextIn: editor.selectedRange, replacementText: "\n"))
        editor.unmarkText()
        editor.isEditable = false
        editor.handleReturn(command)
        #expect(submissions.count == 1)
    }

    @Test
    func changingThePreferenceKeepsTheMountedEditorAndSelection() async throws {
        let suite = "MobileMessageTextEditorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var text = "keep this draft"
        let controller = UIHostingController(
            rootView: MobileMessageTextEditor(
                text: Binding(get: { text }, set: { text = $0 }), maximumLines: 6, submit: {}
            ).defaultAppStorage(defaults))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        window.addSubview(controller.view)
        controller.view.frame = window.bounds
        defer { controller.view.removeFromSuperview() }
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        func find(_ view: UIView) -> MobileMessageTextView? {
            if let editor = view as? MobileMessageTextView { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        let editor = try #require(find(controller.view))
        editor.selectedRange = NSRange(location: 2, length: 4)
        defaults.set(InputSendShortcut.commandReturn.rawValue, forKey: SettingsKey.inputSendShortcut)
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        #expect(find(controller.view) === editor)
        #expect(editor.selectedRange == NSRange(location: 2, length: 4))
        #expect(editor.sendShortcut == .commandReturn)
        #expect(editor.returnKeyType == .default)
        #expect(editor.text == "keep this draft")
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import UIKit

struct MobileMessageTextEditor: UIViewRepresentable {
    @Binding var text: String
    var focus: Binding<Bool>?
    var prompt = ""
    var maximumLines: Int?
    let submit: () -> Void

    @AppStorage(SettingsKey.inputSendShortcut) private var sendShortcut = InputSendShortcut.returnKey
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> MobileMessageTextView {
        MobileMessageTextView()
    }

    func updateUIView(_ view: MobileMessageTextView, context: Context) {
        view.onTextChange = { text = $0 }
        view.onFocusChange = { focus?.wrappedValue = $0 }
        view.submit = submit
        view.sendShortcut = sendShortcut
        view.isEditable = isEnabled
        view.placeholder = prompt
        view.accessibilityLabel = prompt.isEmpty ? nil : prompt
        let font = UIFont.preferredFont(forTextStyle: .body)
        if view.font != font { view.font = font }
        let returnType: UIReturnKeyType = sendShortcut == .returnKey ? .send : .default
        if view.returnKeyType != returnType {
            view.returnKeyType = returnType
            if view.isFirstResponder { view.reloadInputViews() }
        }
        if view.text != text, view.markedTextRange == nil {
            let selection = view.selectedRange
            view.text = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            view.selectedRange = NSRange(location: location, length: min(selection.length, length - location))
        }
        view.refreshPlaceholder()
        if let focus, focus.wrappedValue != view.isFirstResponder {
            DispatchQueue.main.async { [weak view] in
                guard let view, view.window != nil else { return }
                if focus.wrappedValue, view.isEditable {
                    view.becomeFirstResponder()
                } else if !focus.wrappedValue {
                    view.resignFirstResponder()
                }
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MobileMessageTextView, context: Context) -> CGSize? {
        guard let maximumLines, let width = proposal.width else { return nil }
        let lineHeight = uiView.font?.lineHeight ?? 20
        let natural = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(max(lineHeight, natural), lineHeight * CGFloat(maximumLines))
        return CGSize(width: width, height: ceil(height))
    }

    static func dismantleUIView(_ view: MobileMessageTextView, coordinator: Void) {
        view.submit = {}
        view.onTextChange = { _ in }
        view.onFocusChange = { _ in }
        view.resignFirstResponder()
    }
}

final class MobileMessageTextView: UITextView, UITextViewDelegate {
    var sendShortcut = InputSendShortcut.returnKey
    var submit: () -> Void = {}
    var onTextChange: (String) -> Void = { _ in }
    var onFocusChange: (Bool) -> Void = { _ in }
    var placeholder = "" {
        didSet { placeholderLabel.text = placeholder }
    }
    private let placeholderLabel = UILabel()
    private var insertingLiteralText = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        backgroundColor = .clear
        textColor = .label
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        textContainerInset = .zero
        textContainer.lineFragmentPadding = 0
        allowsEditingTextAttributes = false
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isAccessibilityElement = false
        addSubview(placeholderLabel)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeholderLabel.font = font
        placeholderLabel.frame = CGRect(
            origin: .zero,
            size: placeholderLabel.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)))
    }

    var ownsInputActions: Bool { isEditable && isFirstResponder && window?.isKeyWindow == true }

    override var keyCommands: [UIKeyCommand]? {
        let modifiers: [UIKeyModifierFlags] = [.command, .shift, [.command, .shift]]
        let commands = modifiers.map { modifiers in
            let command = UIKeyCommand(input: "\r", modifierFlags: modifiers, action: #selector(handleReturn(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        return commands + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handleReturn(_:)) { return ownsInputActions && markedTextRange == nil }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc func handleReturn(_ command: UIKeyCommand) {
        guard ownsInputActions else { return }
        switch sendShortcut.returnAction(
            command: command.modifierFlags.contains(.command), shift: command.modifierFlags.contains(.shift),
            control: command.modifierFlags.contains(.control), option: command.modifierFlags.contains(.alternate),
            hasMarkedText: markedTextRange != nil
        ) {
        case .submit:
            submit()
        case .newline:
            insertLiteralNewline()
        case .system:
            break
        }
    }

    func insertLiteralNewline() {
        insertingLiteralText = true
        defer { insertingLiteralText = false }
        insertText("\n")
    }

    override func insertText(_ text: String) {
        if consumesReturn(text) { return }
        super.insertText(text)
    }

    override func paste(_ sender: Any?) {
        // A pasted newline is text, never a request to send.
        insertingLiteralText = true
        defer { insertingLiteralText = false }
        super.paste(sender)
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        !consumesReturn(text)
    }

    private func consumesReturn(_ text: String) -> Bool {
        guard text == "\n", !insertingLiteralText, ownsInputActions,
            sendShortcut.returnAction(command: false, hasMarkedText: markedTextRange != nil) == .submit
        else { return false }
        submit()
        return true
    }

    func textViewDidChange(_ textView: UITextView) {
        refreshPlaceholder()
        invalidateIntrinsicContentSize()
        onTextChange(textView.text)
    }

    func textViewDidBeginEditing(_ textView: UITextView) { onFocusChange(true) }
    func textViewDidEndEditing(_ textView: UITextView) { onFocusChange(false) }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        refreshPlaceholder()
    }

    override func unmarkText() {
        super.unmarkText()
        refreshPlaceholder()
    }

    func refreshPlaceholder() {
        placeholderLabel.isHidden = !text.isEmpty || markedTextRange != nil
    }
}

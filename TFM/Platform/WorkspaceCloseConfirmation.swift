// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindPresentation

enum WorkspaceCloseConfirmation {
    static func confirmDiscardTerminalTheme() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: AppStrings.Common.discardChangesQuestion)
        alert.addButton(withTitle: String(localized: AppStrings.Common.cancel))
        alert.addButton(withTitle: String(localized: AppStrings.Common.discardChanges))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Preserve native delegate vetoes and unsaved edits without prompting for live connections.
nonisolated final class WorkspaceWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var forwardedDelegate: (any NSWindowDelegate)?
    @MainActor private weak var window: NSWindow?
    @MainActor private let model: WindowModel
    @MainActor private let confirmDiscardTheme: () -> Bool
    @MainActor private var isConfirming = false

    @MainActor
    init(
        model: WindowModel,
        confirmDiscardTheme: @escaping () -> Bool = { WorkspaceCloseConfirmation.confirmDiscardTerminalTheme() }
    ) {
        self.model = model
        self.confirmDiscardTheme = confirmDiscardTheme
        super.init()
    }

    @MainActor
    func attach(to window: NSWindow?) {
        if self.window !== window {
            if self.window?.delegate === self { self.window?.delegate = forwardedDelegate }
            self.window = window
        }
        guard let window, window.delegate !== self else { return }
        forwardedDelegate = window.delegate
        window.delegate = self
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
        return super.forwardingTarget(for: selector)
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isConfirming else { return false }
        guard forwardedDelegate?.windowShouldClose?(sender) != false else { return false }
        isConfirming = true
        defer { isConfirming = false }
        model.saveTerminalThemeChanges()
        if model.hasUnsavedTerminalThemeChanges, !confirmDiscardTheme() { return false }
        model.clearTerminalThemeEditor()
        return true
    }
}

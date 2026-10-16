import AppKit
import TermindPresentation

enum WorkspaceCloseConfirmation {
    case window
    case application

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        switch self {
        case .window:
            alert.messageText = String(localized: AppStrings.Workspace.closeThisWindowConfirmation)
            alert.informativeText = String(localized: AppStrings.Workspace.closeWindowWarning)
        case .application:
            alert.messageText = String(localized: AppStrings.Workspace.quitTermindConfirmation)
            alert.informativeText = String(localized: AppStrings.Workspace.quitTermindWarning)
        }
        let close = alert.addButton(
            withTitle: String(
                localized: self == .window ? AppStrings.Workspace.closeWindow : AppStrings.Workspace.closeTermind))
        let cancel = alert.addButton(withTitle: String(localized: AppStrings.Common.cancel))
        close.keyEquivalent = "\r"
        cancel.keyEquivalent = "\u{1b}"
        return alert
    }

    func confirm(present: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) -> Bool {
        present(makeAlert()) == .alertFirstButtonReturn
    }

    static func confirmDiscardTerminalTheme() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: AppStrings.Common.discardChangesQuestion)
        alert.addButton(withTitle: String(localized: AppStrings.Common.cancel))
        alert.addButton(withTitle: String(localized: AppStrings.Common.discardChanges))
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Window dismissal and application termination have different scopes. Keep the
/// window veto out of SwiftUI's dismissal dialog, which also participates in Quit.
nonisolated final class WorkspaceWindowCloseDelegate: NSObject, NSWindowDelegate {
    weak var forwardedDelegate: (any NSWindowDelegate)?
    @MainActor private weak var window: NSWindow?
    @MainActor private let model: WindowModel
    @MainActor private let confirmClose: () -> Bool
    @MainActor private let confirmDiscardTheme: () -> Bool
    @MainActor private var isConfirming = false

    @MainActor
    convenience init(
        model: WindowModel, confirmClose: @escaping () -> Bool = { WorkspaceCloseConfirmation.window.confirm() }
    ) {
        self.init(
            model: model, confirmClose: confirmClose,
            confirmDiscardTheme: { WorkspaceCloseConfirmation.confirmDiscardTerminalTheme() })
    }

    @MainActor
    init(
        model: WindowModel, confirmClose: @escaping () -> Bool, confirmDiscardTheme: @escaping () -> Bool
    ) {
        self.model = model
        self.confirmClose = confirmClose
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
        if !model.isClosed, !model.workspaces.isEmpty, !confirmClose() { return false }
        model.clearTerminalThemeEditor()
        return true
    }
}

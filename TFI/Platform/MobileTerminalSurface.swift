import GhosttyTerminal
import TermindApplication
import TermindDomain
import TermindPresentation
import UIKit

/// A workspace owns its native surface even while SwiftUI navigates away from it.
@MainActor
final class MobileTerminalSurface {
    let view: MobileTerminalView = {
        let view = MobileTerminalView(frame: .zero)
        view.usesInlineTextSelection = true
        view.touchSelectionTitles = TerminalTouchSelectionTitles(
            paste: String(localized: AppStrings.Common.paste),
            select: String(localized: AppStrings.Common.select),
            selectAll: String(localized: AppStrings.Common.selectAll),
            copy: String(localized: AppStrings.Common.copy)
        )
        return view
    }()

    func bindFind(_ find: TerminalFindController) {
        view.findController = find
    }
}

/// Adds app-level terminal-find equivalents without taking ordinary terminal
/// input away from Ghostty. Escape is replaced only while Find is presented.
@MainActor
final class MobileTerminalView: TerminalView {
    weak var findController: TerminalFindController?

    override func inputAccessoryAccessibilityLabel(for item: TerminalInputAccessoryItem) -> String? {
        let title: LocalizedStringResource
        switch item {
        case .esc: title = AppStrings.Terminal.escape
        case .tab: title = AppStrings.Terminal.tab
        case .ctrl: title = AppStrings.Terminal.control
        case .alt: title = AppStrings.Terminal.option
        case .command: title = AppStrings.Terminal.commandKey
        case .arrowLeft: title = AppStrings.Terminal.leftArrow
        case .arrowUp: title = AppStrings.Terminal.upArrow
        case .arrowDown: title = AppStrings.Terminal.downArrow
        case .arrowRight: title = AppStrings.Terminal.rightArrow
        case .paste: title = AppStrings.Common.paste
        case .symbol(let symbol): return symbol
        case .divider: return nil
        }
        return String(localized: title)
    }

    override func inputAccessoryAccessibilityValue(for activation: TerminalPublicStickyActivation) -> String {
        switch activation {
        case .inactive: String(localized: AppStrings.Terminal.inactive)
        case .armed: String(localized: AppStrings.Terminal.armed)
        case .locked: String(localized: AppStrings.Terminal.locked)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(findCommand(title: AppStrings.Terminal.findNextInTerminal, modifiers: []))
        commands.append(findCommand(title: AppStrings.Terminal.findPreviousInTerminal, modifiers: .shift))

        guard findController?.isPresented == true else { return commands }
        commands.removeAll(where: isDismissFindEquivalent)
        commands.append(dismissFindCommand(modifiers: []))
        commands.append(dismissFindCommand(modifiers: .shift))
        return commands
    }

    @objc private func handleFindCommand(_ command: UIKeyCommand) {
        findController?.presentAndNavigate(command.modifierFlags.contains(.shift) ? .next : .previous)
    }

    @objc private func handleDismissFindCommand(_: UIKeyCommand) {
        findController?.dismiss()
    }

    private func findCommand(title: LocalizedStringResource, modifiers: UIKeyModifierFlags) -> UIKeyCommand {
        let command = UIKeyCommand(
            title: String(localized: title),
            action: #selector(handleFindCommand(_:)),
            input: UIKeyCommand.f3,
            modifierFlags: modifiers
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private func dismissFindCommand(modifiers: UIKeyModifierFlags) -> UIKeyCommand {
        let command = UIKeyCommand(
            title: String(localized: AppStrings.Terminal.closeFind),
            action: #selector(handleDismissFindCommand(_:)),
            input: UIKeyCommand.inputEscape,
            modifierFlags: modifiers
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    private func isDismissFindEquivalent(_ command: UIKeyCommand) -> Bool {
        guard command.input == UIKeyCommand.inputEscape else { return false }
        let modifiers = command.modifierFlags.intersection([.command, .control, .alternate, .shift])
        return modifiers.isEmpty || modifiers == .shift
    }
}

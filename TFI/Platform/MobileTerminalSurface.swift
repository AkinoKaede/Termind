import GhosttyTerminal
import TermindApplication
import TermindDomain
import UIKit

/// A workspace owns its native surface even while SwiftUI navigates away from it.
@MainActor
final class MobileTerminalSurface {
    let view = MobileTerminalView(frame: .zero)

    func bindFind(_ find: TerminalFindController) {
        view.findController = find
    }
}

/// Adds app-level terminal-find equivalents without taking ordinary terminal
/// input away from Ghostty. Escape is replaced only while Find is presented.
@MainActor
final class MobileTerminalView: TerminalView {
    weak var findController: TerminalFindController?

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        commands.append(findCommand(title: "Find Next in Terminal", modifiers: []))
        commands.append(findCommand(title: "Find Previous in Terminal", modifiers: .shift))

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
            title: String(localized: "Close Find"),
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

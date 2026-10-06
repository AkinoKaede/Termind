import SwiftUI

/// The primary close key follows the visible workspace on both platforms.
struct WindowCloseShortcuts {
    let closeWindow: KeyboardShortcut
    let closeAllWindows = KeyboardShortcut("w", modifiers: [.command, .option])
    let closeWorkspace: KeyboardShortcut?

    init(hasWorkspace: Bool) {
        closeWindow = KeyboardShortcut("w", modifiers: hasWorkspace ? [.command, .shift] : .command)
        closeWorkspace = hasWorkspace ? KeyboardShortcut("w", modifiers: .command) : nil
    }
}

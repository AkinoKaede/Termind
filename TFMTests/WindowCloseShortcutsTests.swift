// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import Testing

@testable import Termind

@Suite @MainActor
struct WindowCloseShortcutsTests {
    @Test func primaryCloseKeyMovesFromWorkspaceToWindowWithoutConflicts() {
        let workspace = WindowCloseShortcuts(hasWorkspace: true)
        #expect(workspace.closeWindow == KeyboardShortcut("w", modifiers: [.command, .shift]))
        #expect(workspace.closeWorkspace == KeyboardShortcut("w", modifiers: .command))

        let window = WindowCloseShortcuts(hasWorkspace: false)
        #expect(window.closeWindow == KeyboardShortcut("w", modifiers: .command))
        #expect(window.closeWorkspace == nil)

        for state in [workspace, window] {
            #expect(state.closeAllWindows == KeyboardShortcut("w", modifiers: [.command, .option]))
            let shortcuts = [state.closeWindow, state.closeAllWindows, state.closeWorkspace].compactMap { $0 }
            #expect(Set(shortcuts).count == shortcuts.count)
        }
    }
}

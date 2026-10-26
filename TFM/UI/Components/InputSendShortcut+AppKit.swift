// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import TermindApplication

extension InputSendShortcut {
    func action(for event: NSEvent, hasMarkedText: Bool) -> Action {
        guard event.keyCode == 36 || event.keyCode == 76 else { return .system }
        return returnAction(
            command: event.modifierFlags.contains(.command), shift: event.modifierFlags.contains(.shift),
            control: event.modifierFlags.contains(.control), option: event.modifierFlags.contains(.option),
            hasMarkedText: hasMarkedText)
    }
}

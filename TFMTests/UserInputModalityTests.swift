// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import Termind

struct UserInputModalityTests {
    @Test(arguments: [
        NSEvent.EventType.leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ])
    func pointerPressesSwitchToPointer(_ eventType: NSEvent.EventType) {
        #expect(UserInputModality.keyboard.updated(for: eventType) == .pointer)
    }

    @Test
    func keyDownSwitchesToKeyboard() {
        #expect(UserInputModality.pointer.updated(for: .keyDown) == .keyboard)
    }

    @Test(arguments: [
        NSEvent.EventType.mouseMoved,
        .scrollWheel,
        .keyUp,
    ])
    func unrelatedEventsPreserveTheCurrentModality(_ eventType: NSEvent.EventType) {
        #expect(UserInputModality.pointer.updated(for: eventType) == .pointer)
        #expect(UserInputModality.keyboard.updated(for: eventType) == .keyboard)
    }
}

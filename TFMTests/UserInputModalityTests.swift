import AppKit
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
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

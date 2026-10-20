// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Observation
import SwiftUI

nonisolated enum UserInputModality: Equatable, Sendable {
    case keyboard
    case pointer

    func updated(for eventType: NSEvent.EventType) -> Self {
        switch eventType {
        case .keyDown:
            .keyboard
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            .pointer
        default:
            self
        }
    }
}

/// The most recent input family used inside Termind.
///
/// AppKit makes the first focusable control in a newly mounted hosting view the
/// first responder. With full keyboard navigation enabled that programmatic
/// focus draws exactly like keyboard navigation, even when the user opened the
/// surface with the mouse. Observing the input event without consuming it lets
/// custom controls keep the useful keyboard ring while suppressing that
/// pointer-triggered false signal.
@MainActor
@Observable
final class UserInputModalityTracker {
    static let shared = UserInputModalityTracker()

    private(set) var modality: UserInputModality = .pointer
    @ObservationIgnored private var eventMonitor: Any?

    private init() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.record(event.type)
            return event
        }
    }

    /// Status-item clicks can arrive from Control Center without a local mouse event.
    func notePointerInteraction() { record(.leftMouseDown) }

    private func record(_ eventType: NSEvent.EventType) {
        let updated = modality.updated(for: eventType)
        if updated != modality { modality = updated }
    }
}

private struct InputAwareFocusEffect: ViewModifier {
    @State private var input = UserInputModalityTracker.shared

    func body(content: Content) -> some View {
        content.focusEffectDisabled(input.modality != .keyboard)
    }
}

extension View {
    /// Shows the native focus ring only after actual keyboard input.
    func termindInputAwareFocusEffect() -> some View {
        modifier(InputAwareFocusEffect())
    }
}

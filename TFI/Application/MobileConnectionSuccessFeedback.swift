// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

/// Consume readiness synchronously, rather than replaying a SwiftUI change after returning to the foreground.
@MainActor
final class MobileConnectionSuccessFeedback {
    private let observerID = UUID()
    private weak var journey: ConnectionJourney?

    isolated deinit { stop() }

    func observe(_ journey: ConnectionJourney, canPresent: @escaping () -> Bool, feedback: @escaping () -> Void) {
        stop()
        self.journey = journey
        journey.observeSuccess(id: observerID) { [weak self] in
            guard self != nil, canPresent() else { return false }
            feedback()
            return true
        }
    }

    func stop() {
        journey?.removeSuccessObserver(observerID)
        journey = nil
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import Termind

@Suite @MainActor
struct WorkspaceDragCancellationTests {
    @Test
    func escapeRemainsCancelledAfterReleaseAndRepeatedActiveCallbacks() {
        let tracker = WorkspaceDragCancellationTracker()
        tracker.begin()
        tracker.recordEscape()
        tracker.begin()
        let wasCancelled = tracker.end()

        #expect(wasCancelled)
        #expect(
            !WorkspaceLayoutDragCompletion.shouldTearOff(
                operation: [], primaryButtonPressed: false, cancelled: wasCancelled,
                payloadMatches: true, screenPoint: CGPoint(x: 900, y: 900), windowFrames: []
            ))

        tracker.begin()
        #expect(!tracker.end())
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import Testing

@testable import Termind

@MainActor
struct AppTestHostTests {
    @Test
    func defaultTestHostDoesNotPresentWindowsOrReopenTheMainScene() {
        guard TermindApp.suppressesAutomaticTestWindows else { return }
        #expect(NSApp.windows.allSatisfy { !$0.isVisible })
        let delegate = AppDelegate()
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
    }

    @Test
    func closingTheLastFixtureWindowDoesNotTerminateTheTestHost() {
        #expect(!AppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}

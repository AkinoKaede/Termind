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

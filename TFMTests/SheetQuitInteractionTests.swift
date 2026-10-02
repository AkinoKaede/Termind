import AppKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPersistence
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor
struct SheetQuitInteractionTests {
    @Test(arguments: ["connect", "batch", "pro"])
    func nativeQuitWorksWithSheetFocusAndAfterCancellingAndReopening(_ surface: String) async throws {
        let app = AppModel(hosts: HostLibraryModel(), proAccess: .testing(status: .free))
        let model = WindowModel()
        let root = RootView(window: model)
            .environment(app)
            .modelContainer(try TermindPersistence.makeContainer(inMemory: true))
        let window = makeWindow()
        let otherWindow = makeWindow()
        let originalDelegate = NSApp.delegate
        let delegate = CancellingTerminationDelegate()
        defer {
            NSApp.delegate = delegate
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.orderOut(nil)
            otherWindow.orderOut(nil)
            window.contentViewController = nil
            window.close()
            otherWindow.close()
            NSApp.delegate = originalDelegate
            app.shutdownForTermination()
        }
        window.contentViewController = NSHostingController(rootView: root)
        otherWindow.makeKeyAndOrderFront(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitUntil(timeout: .seconds(10)) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
            window.makeMain()
            window.makeKey()
            return window.isKeyWindow
        }
        // Keep SwiftUI's delegate during launch and activation. Only replace
        // it once the window is ready, to cancel the real terminate: action
        // without terminating the test host or starting the live app's cleanup.
        NSApp.delegate = delegate
        let originalWindowPolicy = window.preventsApplicationTerminationWhenModal

        for cycle in 0..<2 {
            if surface == "pro" {
                app.proAccess.presentPaywall()
            } else {
                model.presentations.hostChooser = surface == "connect" ? .connect : .batchStartup
            }
            try await waitUntil {
                guard let sheet = window.attachedSheet else { return false }
                return sheet.isKeyWindow && !sheet.preventsApplicationTerminationWhenModal
            }
            let sheet = try #require(window.attachedSheet)
            if surface != "pro" {
                let content = try #require(sheet.contentView)
                let field = try #require(
                    descendants(content).compactMap { $0 as? NSTextField }.first { $0.isEditable })
                #expect(sheet.makeFirstResponder(field))
                try await waitUntil { field.currentEditor() === sheet.firstResponder }
            }
            #expect(window.preventsApplicationTerminationWhenModal == originalWindowPolicy)
            #expect(otherWindow.preventsApplicationTerminationWhenModal)

            let quitItem = try #require(NSApp.mainMenu.flatMap(findQuitItem))
            quitItem.menu?.update()
            #expect(quitItem.isEnabled)
            #expect(quitItem.keyEquivalent == "q")
            try commandQ(in: sheet)
            try await waitUntil { delegate.requests == cycle * 2 + 1 }
            #expect(window.isVisible && otherWindow.isVisible)
            #expect(window.attachedSheet === sheet)
            // Cancelling termination must leave the same sheet usable, and
            // a second explicit Quit must still reach the application.
            try commandQ(in: sheet)
            try await waitUntil { delegate.requests == cycle * 2 + 2 }

            model.presentations.hostChooser = nil
            app.proAccess.isPaywallPresented = false
            try await waitUntil { window.attachedSheet == nil }
            #expect(window.preventsApplicationTerminationWhenModal == originalWindowPolicy)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.preventsApplicationTerminationWhenModal = true
        return window
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func findQuitItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == #selector(NSApplication.terminate(_:)) { return item }
            if let submenu = item.submenu, let quit = findQuitItem(in: submenu) { return quit }
        }
        return nil
    }

    private func commandQ(in window: NSWindow) throws {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
        NSApp.sendEvent(event)
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(
            condition(),
            "Sheet or Quit did not finish updating; active=\(NSApp.isActive), key=\(String(describing: NSApp.keyWindow)).",
            sourceLocation: sourceLocation)
    }
}

@MainActor
private final class CancellingTerminationDelegate: NSObject, NSApplicationDelegate {
    private(set) var requests = 0

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requests += 1
        return .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

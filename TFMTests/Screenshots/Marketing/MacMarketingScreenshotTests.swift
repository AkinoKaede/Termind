import AppKit
import Testing

@testable import Termind

#if DEBUG
    @Suite(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MAC_MARKETING_SCREENSHOTS"] == "1"),
        .serialized)
    @MainActor
    struct MacMarketingScreenshotTests {
        @Test
        func captureDemoInFocusedSystemWindow() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["TERMIND_MAC_MARKETING_SCREENSHOTS"] == "1" else { return }

            let configuration = try #require(ScreenshotDemoConfiguration.active)
            // Capture the production WindowGroup. A second RootView would mount
            // persistent terminal and transcript surfaces in two hierarchies.
            for _ in 0..<100 {
                if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let window = try #require(NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey }))
            window.contentMinSize = .zero
            window.appearance = NSAppearance(named: .aqua)
            window.setFrame(NSRect(origin: .zero, size: configuration.windowSize), display: true)
            window.center()
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .seconds(1))
            window.contentView?.layoutSubtreeIfNeeded()
            if configuration.scene == .hosts {
                window.initialFirstResponder = nil
                window.makeFirstResponder(nil)
            }

            // Keep real pointer hover out of every capture without changing production row styling.
            let originalPointer = NSEvent.mouseLocation
            let desktopTop = try #require(NSScreen.screens.first).frame.maxY
            func movePointer(to point: NSPoint) {
                let location = CGPoint(x: point.x, y: desktopTop - point.y)
                CGWarpMouseCursorPosition(location)
                CGEvent(
                    mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: location, mouseButton: .left
                )?.post(tap: .cghidEventTap)
            }
            defer { movePointer(to: originalPointer) }

            for _ in 0..<3600 {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeMain()
                window.makeKey()
                if NSApp.isActive, window.isKeyWindow {
                    movePointer(to: NSPoint(x: window.frame.midX, y: window.frame.maxY + 16))
                    // Activation can be transient while test hosts launch and exit.
                    // Require the focused appearance to stay active through rendering.
                    try await Task.sleep(for: .milliseconds(300))
                    if NSApp.isActive, window.isKeyWindow { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard NSApp.isActive, window.isKeyWindow else {
                let frontmost = NSWorkspace.shared.frontmostApplication
                let diagnostic =
                    "Marketing window could not become the focused key window: "
                    + "active=\(NSApp.isActive), key=\(window.isKeyWindow), "
                    + "frontmost=\(frontmost?.localizedName ?? "none") "
                    + "pid=\(frontmost?.processIdentifier ?? -1)"
                Issue.record("\(diagnostic)")
                return
            }
            try #require(NSApp.isActive && window.isKeyWindow)
            try #require(window.backingScaleFactor == 2)
            let pointer = NSEvent.mouseLocation
            let contentFrame = window.convertToScreen(window.contentLayoutRect)
            try #require(!contentFrame.contains(pointer), "Pointer must be outside the content before capture")
            // Once hover has cleared, prevent pointer movement during the capture interval
            // from highlighting a card or file row. Restore normal input after the test.
            let ignoredMouseEvents = window.ignoresMouseEvents
            window.ignoresMouseEvents = true
            defer { window.ignoresMouseEvents = ignoredMouseEvents }

            let token = UUID().uuidString
            let scene = configuration.scene.rawValue
            let language = configuration.language.rawValue
            FileHandle.standardOutput.write(
                Data(
                    "TERMIND_MAC_MARKETING_READY \(scene)\t\(language)\t\(window.windowNumber)\t\(token)\tactive\tkey\n"
                        .utf8)
            )

            // Keep the key window alive long enough for the runner to observe the
            // marker and capture it. macOS 27 prevents the runner from reading or
            // acknowledging files inside another app's container.
            try await Task.sleep(for: .seconds(5))
            #expect(NSApp.isActive && window.isKeyWindow, "Capture window lost focus before the capture interval ended")
            #expect(window.ignoresMouseEvents, "Capture window must not accept hover events")
        }
    }
#endif

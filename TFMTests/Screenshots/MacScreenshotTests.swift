import AppKit
import Testing

@testable import Termind

#if DEBUG
    @Suite(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MAC_SCREENSHOTS"] == "1"),
        .serialized)
    @MainActor
    struct MacScreenshotTests {
        @Test
        func captureDemoInFocusedSystemWindow() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["TERMIND_MAC_SCREENSHOTS"] == "1" else { return }

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
            var captureSize = CGSize(
                width: configuration.windowSize.width * 2,
                height: configuration.windowSize.height * 2)
            if configuration.scene == .workspace {
                let screen = try #require(
                    NSScreen.screens.first { screen in
                        guard
                            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
                        else {
                            return false
                        }
                        return CGDisplayIsBuiltin(number.uint32Value) != 0
                    }, "Mac screenshots require the built-in display")
                window.setFrameOrigin(
                    NSPoint(
                        x: screen.frame.midX - window.frame.width / 2,
                        y: screen.frame.midY - window.frame.height / 2))
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.toggleFullScreen(nil)
                for _ in 0..<100 {
                    if window.styleMask.contains(.fullScreen) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try #require(window.styleMask.contains(.fullScreen))
                try await Task.sleep(for: .seconds(2))
                captureSize = CGSize(
                    width: screen.frame.width * screen.backingScaleFactor,
                    height: screen.frame.height * screen.backingScaleFactor)
            } else {
                window.center()
            }
            defer { if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) } }
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
                    // Deliver a move inside the window before leaving it. Warping
                    // straight outside can leave SwiftUI row hover state behind
                    // when the move is delivered to another window or the menu bar.
                    let contentFrame = window.convertToScreen(window.contentLayoutRect)
                    movePointer(to: NSPoint(x: contentFrame.midX, y: contentFrame.maxY - 8))
                    try await Task.sleep(for: .milliseconds(200))
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
                    "Screenshot window could not become the focused key window: "
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
                    "TERMIND_MAC_SCREENSHOT_READY \(scene)\t\(language)\t\(window.windowNumber)\t\(token)\tactive\tkey\t\(Int(captureSize.width))\t\(Int(captureSize.height))\n"
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

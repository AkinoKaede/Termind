import AppKit
import Testing

@testable import Termind

#if DEBUG
    @Suite(.serialized)
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

            for _ in 0..<100 {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeMain()
                window.makeKey()
                if NSApp.isActive, window.isKeyWindow {
                    // Activation can be transient while test hosts launch and exit.
                    // Require the focused appearance to stay active through rendering.
                    try await Task.sleep(for: .milliseconds(300))
                    if NSApp.isActive, window.isKeyWindow { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard NSApp.isActive, window.isKeyWindow else {
                Issue.record("Marketing window could not become the focused key window")
                return
            }
            try #require(NSApp.isActive && window.isKeyWindow)
            try #require(window.backingScaleFactor == 2)

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
        }
    }
#endif

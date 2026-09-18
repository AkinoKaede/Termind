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

            for _ in 0..<100 {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                NSApp.activate(ignoringOtherApps: true)
                window.orderFrontRegardless()
                window.makeMain()
                window.makeKey()
                if NSApp.isActive, window.isKeyWindow { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard NSApp.isActive, window.isKeyWindow else {
                Issue.record("Marketing window could not become the focused key window")
                return
            }
            if configuration.scene == .hosts {
                window.initialFirstResponder = nil
                window.makeFirstResponder(nil)
            }
            // Allow the active appearance to render before the external capture.
            try await Task.sleep(for: .milliseconds(300))
            try #require(NSApp.isActive && window.isKeyWindow)
            try #require(window.backingScaleFactor == 2)

            let control = FileManager.default.temporaryDirectory.appending(path: "marketing-capture-control")
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let ready = control.appending(path: "ready")
            let scene = configuration.scene.rawValue
            let language = configuration.language.rawValue
            try "\(scene)\t\(language)\t\(window.windowNumber)\t\(token)\tactive\tkey\n".write(
                to: ready, atomically: true, encoding: .utf8)
            FileHandle.standardOutput.write(
                Data("TERMIND_MAC_MARKETING_READY \(ready.path)\n".utf8)
            )

            let acknowledgement = control.appending(path: "ack-\(token)")
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: acknowledgement.path) {
                    #expect(NSApp.isActive && window.isKeyWindow, "Capture window lost focus before acknowledgement")
                    try? FileManager.default.removeItem(at: acknowledgement)
                    try? FileManager.default.removeItem(at: ready)
                    return
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try? FileManager.default.removeItem(at: ready)
            Issue.record("Timed out waiting for the macOS marketing screenshot capture")
        }
    }
#endif

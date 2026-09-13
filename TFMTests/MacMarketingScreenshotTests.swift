import AppKit
import SwiftData
import SwiftUI
import TermindApplication
import TermindPersistence
import Testing

@testable import Termind

#if DEBUG
    @Suite(.serialized)
    @MainActor
    struct MacMarketingScreenshotTests {
        @Test
        func captureWorkspaceInSystemWindow() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard environment["TERMIND_MAC_MARKETING_SCREENSHOTS"] == "1" else { return }

            let argument = environment["TERMIND_MAC_MARKETING_LOCALE"] ?? "en"
            let language: AppLanguage
            switch argument {
            case "zh-Hans": language = .simplifiedChinese
            case "zh-Hant": language = .traditionalChinese
            default: language = .english
            }

            let configuration = ScreenshotDemoConfiguration(scene: .workspace, language: language)
            let hosts = HostLibraryModel.demo(language: language)
            let app = AppModel(
                hosts: hosts,
                ai: .demo(),
                proAccess: .unrestrictedForTesting(),
                onboarding: OnboardingController(automaticPresentationEnabled: false),
                serverMetrics: configuration.makeMetricsModel(hosts: hosts)
            )
            let container = try TermindPersistence.makeContainer(inMemory: true)
            let root = RootView(window: configuration.makeWindow(hosts: hosts))
                .environment(app)
                .environment(\.locale, language.locale)
                .modelContainer(container)
            let controller = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: configuration.windowSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.contentMinSize = .zero
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.appearance = NSAppearance(named: .aqua)
            window.contentViewController = controller
            window.setFrame(NSRect(origin: .zero, size: configuration.windowSize), display: true)
            window.center()
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                app.shutdownForTermination()
            }

            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .seconds(1))
            controller.view.layoutSubtreeIfNeeded()

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

            let control = FileManager.default.temporaryDirectory.appending(path: "marketing-capture-control")
            try FileManager.default.createDirectory(at: control, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let ready = control.appending(path: "ready")
            try "workspace\t\(argument)\t\(window.windowNumber)\t\(token)\tactive\tkey\n".write(
                to: ready, atomically: true, encoding: .utf8)
            FileHandle.standardOutput.write(
                Data("TERMIND_MAC_MARKETING_READY \(ready.path)\n".utf8)
            )

            let acknowledgement = control.appending(path: "ack-\(token)")
            for _ in 0..<600 {
                if FileManager.default.fileExists(atPath: acknowledgement.path) {
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

import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@Suite(.serialized) @MainActor
struct TerminalSettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func terminalMouseSettingsRenderInSupportedLanguages(_ language: String) async throws {
        let app = AppModel(hosts: HostLibraryModel())
        let model = WindowModel(workspaces: [])
        model.openSettings(route: .category(.terminal))
        defer { app.shutdownForTermination() }
        let view = SettingsPageView().environment(app).environment(model)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 640, height: 1100)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 1100),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "terminal-mouse-settings-\(language).png")
        #expect(data.count > 20_000)
    }
}

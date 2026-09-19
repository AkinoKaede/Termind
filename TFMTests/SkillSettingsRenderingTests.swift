import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind

@Suite(.requiresVisibleWindow, .serialized) @MainActor struct SkillSettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func aiSettingsShowUserSkillsAndMemoryAfterMCP(_ language: String) async throws {
        let app = AppModel(hosts: HostLibraryModel(), skills: SkillLibraryModel())
        let model = WindowModel(workspaces: [])
        model.openSettings(route: .category(.ai))
        defer { app.shutdownForTermination() }
        let view = SettingsPageView().environment(app).environment(model)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 640, height: 1300)
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 1300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(600))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try #require(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "ai-skills-memory-\(language).png")
        #expect(data.count > 20_000)
    }
}

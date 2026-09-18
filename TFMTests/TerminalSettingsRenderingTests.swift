import AppKit
import SwiftUI
import TermindApplication
import Testing

@testable import Termind
@testable import TermindPresentation

@Suite(.serialized) @MainActor
struct TerminalSettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], ["", "Menlo"])
    func terminalSettingsRenderInSupportedLanguages(_ language: String, family: String) async throws {
        let domain = "TerminalFontRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(family, forKey: SettingsKey.terminalFontFamily)
        defaults.set(family.isEmpty, forKey: SettingsKey.terminalFontFollowTheme)
        let app = AppModel(hosts: HostLibraryModel())
        let model = WindowModel(workspaces: [])
        model.openSettings(route: .category(.terminal))
        defer { app.shutdownForTermination() }
        let view = SettingsPageView().environment(app).environment(model)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 640, height: 1100)
        try await capture(
            view, name: "terminal-settings-\(language)-\(family.isEmpty ? "theme" : family)",
            size: NSSize(width: 640, height: 1100))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func fontNamesPreviewTheirOwnFamilies(_ language: String) async throws {
        let view = TerminalFontOptions(
            family: .constant("Menlo"), families: ["Courier", "Menlo", "Monaco"], didSelect: {}
        )
        .environment(\.locale, Locale(identifier: language))
        .frame(width: 280, height: 320)
        .background(.background)
        try await capture(view, name: "terminal-font-options-\(language)", size: NSSize(width: 280, height: 320))
    }

    private func capture(_ view: some View, name: String, size: NSSize) async throws {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
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
        Attachment.record(data, named: "\(name).png")
        #expect(data.count > 5_000)
    }
}

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
        defaults.set(18.0, forKey: SettingsKey.terminalFontSize)
        let app = AppModel(hosts: HostLibraryModel())
        let model = WindowModel(workspaces: [])
        model.openSettings(route: .category(.terminal))
        defer { app.shutdownForTermination() }
        let view = SettingsPageView().environment(app).environment(model)
            .defaultAppStorage(defaults)
            .environment(\.locale, Locale(identifier: language))
            .frame(width: 640, height: 1100)
        let name = "terminal-settings-\(language)-\(family.isEmpty ? "theme" : family)"
        try await withWindow(view, size: NSSize(width: 640, height: 1100)) { hostedView in
            for (index, followsTheme) in [false, true, false].enumerated() {
                defaults.set(followsTheme, forKey: SettingsKey.terminalFontFollowTheme)
                try await capture(
                    hostedView, name: "\(name)-\(followsTheme ? "theme-size" : "custom-size")-\(index)")
                #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 18)
                #expect(defaults.string(forKey: SettingsKey.terminalFontFamily) == family)
            }
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func fontNamesPreviewTheirOwnFamilies(_ language: String) async throws {
        let view = TerminalFontOptions(
            family: .constant("Menlo"), families: ["Courier", "Menlo", "Monaco"], didSelect: {}
        )
        .environment(\.locale, Locale(identifier: language))
        .frame(width: 280, height: 320)
        .background(.background)
        try await withWindow(view, size: NSSize(width: 280, height: 320)) { hostedView in
            try await capture(hostedView, name: "terminal-font-options-\(language)")
        }
    }

    private func withWindow(_ view: some View, size: NSSize, perform: (NSView) async throws -> Void) async rethrows {
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
        try await perform(controller.view)
    }

    private func capture(_ view: NSView, name: String) async throws {
        try await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(data, named: "\(name).png")
        #expect(data.count > 5_000)
    }
}

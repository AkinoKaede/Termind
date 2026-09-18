import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindPresentation

@Suite(.serialized) @MainActor
struct MobileTerminalFontTests {
    @Test func fontCatalogIncludesOnlyAvailableMonospacedFamilies() {
        TerminalFontCatalog.shared.refresh()
        #expect(!TerminalFontCatalog.shared.families.isEmpty)
        #expect(!TerminalFontCatalog.shared.families.contains("Helvetica"))
        for family in TerminalFontCatalog.shared.families {
            #expect(
                UIFont.fontNames(forFamilyName: family).contains {
                    UIFont(name: $0, size: 14)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
                })
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func fontNamesPreviewTheirOwnFamilies(_ language: String) async throws {
        let view = TerminalFontOptions(
            family: .constant("Menlo"), families: ["Courier", "Menlo", "Courier New"], didSelect: {}
        )
        .environment(\.locale, Locale(identifier: language))
        .frame(width: 280, height: 320)
        .background(.background)
        try await withWindow(view) { window in
            try await capture(window, name: "mobile-terminal-font-options-\(language)")
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], ["", "Menlo"])
    func terminalFontSettingsRenderInSupportedLanguages(_ language: String, family: String) async throws {
        let domain = "MobileTerminalFontRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(family, forKey: SettingsKey.terminalFontFamily)
        defaults.set(18.0, forKey: SettingsKey.terminalFontSize)
        let view = NavigationStack {
            MobileTerminalSettingsView(model: TerminalSettingsModel())
        }
        .defaultAppStorage(defaults)
        .environment(\.locale, Locale(identifier: language))
        let name = "mobile-terminal-settings-\(language)-\(family.isEmpty ? "theme" : family)"
        try await withWindow(view) { window in
            for (index, followsTheme) in [false, true, false].enumerated() {
                defaults.set(followsTheme, forKey: SettingsKey.terminalFontFollowTheme)
                try await capture(window, name: "\(name)-\(followsTheme ? "theme-size" : "custom-size")-\(index)")
                #expect(defaults.double(forKey: SettingsKey.terminalFontSize) == 18)
                #expect(defaults.string(forKey: SettingsKey.terminalFontFamily) == family)
            }
        }
    }

    private func withWindow(_ view: some View, perform: (UIWindow) async throws -> Void) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        try await perform(window)
    }

    private func capture(_ window: UIWindow, name: String) async throws {
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10_000)
        Attachment.record(data, named: "\(name).png")
    }
}

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
        try await capture(view, name: "mobile-terminal-font-options-\(language)")
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], ["", "Menlo"])
    func terminalFontSettingsRenderInSupportedLanguages(_ language: String, family: String) async throws {
        let domain = "MobileTerminalFontRendering.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(family, forKey: SettingsKey.terminalFontFamily)
        defaults.set(family.isEmpty, forKey: SettingsKey.terminalFontFollowTheme)
        let view = NavigationStack {
            MobileTerminalSettingsView(model: TerminalSettingsModel())
        }
        .defaultAppStorage(defaults)
        .environment(\.locale, Locale(identifier: language))
        try await capture(view, name: "mobile-terminal-settings-\(language)-\(family.isEmpty ? "theme" : family)")
    }

    private func capture(_ view: some View, name: String) async throws {
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
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        #expect(data.count > 10_000)
        Attachment.record(data, named: "\(name).png")
    }
}

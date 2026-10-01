import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.serialized) @MainActor
struct MobileTerminalThemeTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"),
        arguments: ["en", "zh-Hans", "zh-Hant"], [false, true])
    func themeBrowserSnapshots(language: String, isDark: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let model = TerminalSettingsModel()
        model.selectCustomTheme(isDark: isDark)
        let initial = model.preferences
        let controller = UIHostingController(
            rootView: NavigationStack { MobileTerminalThemeView(model: model, isDark: isDark) }
                .environment(\.locale, Locale(identifier: language))
                .environment(\.colorScheme, isDark ? .dark : .light)
                .environment(\.dynamicTypeSize, language == "zh-Hant" ? .accessibility1 : .large))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "mobile-themes-\(language)-\(isDark ? "dark" : "light").png")
        #expect(data.count > 10_000)
        #expect(model.preferences == initial)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("termind-theme-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(
            to: directory.appendingPathComponent("mobile-themes-\(language)-\(isDark ? "dark" : "light").png"))
    }

    @Test func previewingDraftDoesNotApplyOrEnableIt() {
        let model = TerminalSettingsModel()
        let initial = model.preferences
        let preview = TerminalConfigurationPreviewModel()
        #expect(
            preview.update(
                themeName: initial.lightTheme, text: "background = 123456", isDark: false, font: .init()))
        #expect(model.preferences == initial)
        #expect(!model.preferences.lightCustomEnabled)
        #expect(!preview.terminal.isFocused)
    }
}

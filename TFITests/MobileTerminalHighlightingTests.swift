import SwiftUI
import TermindApplication
import TermindDomain
import Testing
import UIKit

@testable import TermindIOS
@testable import TermindPresentation

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"), .serialized)
@MainActor
struct MobileTerminalHighlightingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func settingsAndEditorFitTheNativeWindow(_ language: String) async throws {
        let model = TerminalHighlightSettingsModel()
        var backgroundRule = TermindDomain.TerminalHighlightPreferences.builtInRules[1]
        backgroundRule.id = UUID()
        backgroundRule.color = .none
        backgroundRule.backgroundColor = .yellow
        #expect(model.upsert(backgroundRule, validate: { _ in true }))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        let views: [(String, AnyView)] = [
            ("settings", AnyView(NavigationStack { MobileTerminalHighlightSettingsView(model: model) })),
            ("editor", AnyView(MobileTerminalHighlightRuleEditor(rule: backgroundRule, model: model))),
        ]
        for (name, view) in views {
            let controller = UIHostingController(rootView: view.environment(\.locale, Locale(identifier: language)))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            #expect(abs(controller.view.bounds.width - window.bounds.width) < 0.5)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let data = try #require(image.pngData())
            Attachment.record(data, named: "mobile-keyword-\(name)-\(language)-\(Int(window.bounds.width)).png")
            #expect(data.count > 20000)
        }
    }
}

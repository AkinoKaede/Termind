import SwiftUI
import TermindApplication
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileSkillSettingsRenderingTests {
    @Test(arguments: ["en", "zh-Hans"])
    func aiOrderingAndUserSkillSettings(_ language: String) async throws {
        let app = try MobileAppModel(inMemory: true)
        try await capture(NavigationStack { MobileAISettingsView(app: app) }, language: language, name: "ai-order")
        try await capture(
            NavigationStack { MobileSkillSettings(skills: app.skills) }, language: language, name: "user-skills")
    }
    private func capture(_ content: some View, language: String, name: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: content.environment(\.locale, Locale(identifier: language)))
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(600))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let bytes = try #require(image.pngData())
        Attachment.record(bytes, named: "\(name)-\(language).png")
    }
}

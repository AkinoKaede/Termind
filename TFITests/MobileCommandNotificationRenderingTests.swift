import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_MOBILE_UI_TESTS"] == "1"), .serialized)
@MainActor
struct MobileCommandNotificationRenderingTests {
    @Test(arguments: ["en", "zh-Hans"], [false, true])
    func notificationSettingsAndBadge(_ language: String, dark: Bool) async throws {
        let model = TerminalSettingsModel()
        var settings = CommandNotificationPreferences()
        settings.mode = .unfocused
        model.set(settings, for: \.commandNotifications)
        let view = Form {
            Section {
                Label {
                    Text("Build Server")
                } icon: {
                    Image(systemName: "terminal")
                        .overlay(alignment: .topTrailing) { WorkspaceCommandBadge().offset(x: 3, y: -3) }
                }
            }
            TerminalCommandNotificationFields(model: model, service: SilentNotifications(), openSettings: {})
        }
        .environment(\.locale, Locale(identifier: language))
        .environment(\.colorScheme, dark ? .dark : .light)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "command-notifications-ios-\(language)-\(dark).png")
    }

    private final class SilentNotifications: CommandNotificationSending {
        func authorization(request: Bool) async -> CommandNotificationAuthorization { .notDetermined }
        func send(sessionID: UUID, title: String, body: String) async {}
    }
}

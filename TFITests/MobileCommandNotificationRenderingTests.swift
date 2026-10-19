import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(.requiresKeyWindow, .serialized)
@MainActor
struct MobileCommandNotificationRenderingTests {
    @Test(arguments: ["en", "zh-Hans"], [false, true])
    func notificationSettingsAndStepper(_ language: String, dark: Bool) async throws {
        let model = NotificationSettingsModel()
        model.set(true, for: \.isEnabled)
        let view = Form {
            NotificationSettingsFields(model: model, service: SilentNotifications(), openSettings: {})
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
        let stepper = try #require(findStepper(in: controller.view))
        #expect(model.preferences.terminalMinimumSeconds == 5 && stepper.stepValue == 1)
        stepper.value += 1
        stepper.sendActions(for: .valueChanged)
        #expect(model.preferences.terminalMinimumSeconds == 6)
        stepper.value -= 1
        stepper.sendActions(for: .valueChanged)
        #expect(model.preferences.terminalMinimumSeconds == 5)
        model.set(0, for: \.terminalMinimumSeconds)
        try await Task.sleep(for: .milliseconds(100))
        stepper.value -= 1
        stepper.sendActions(for: .valueChanged)
        #expect(model.preferences.terminalMinimumSeconds == 0)
        model.set(false, for: \.isEnabled)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!stepper.isEnabled)
        model.set(true, for: \.isEnabled)
        model.set(NotificationPreferences.Mode.never, for: \.terminalMode)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!stepper.isEnabled)
        model.set(NotificationPreferences.Mode.always, for: \.terminalMode)
        try await Task.sleep(for: .milliseconds(100))
        #expect(stepper.isEnabled)
    }

    private func findStepper(in view: UIView) -> UIStepper? {
        if let stepper = view as? UIStepper { return stepper }
        return view.subviews.lazy.compactMap { findStepper(in: $0) }.first
    }

    private final class SilentNotifications: NotificationSending {
        func authorization(request: Bool) async -> NotificationAuthorization { .notDetermined }
        func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {}
        func remove(_ identifiers: [String]) {}
    }
}

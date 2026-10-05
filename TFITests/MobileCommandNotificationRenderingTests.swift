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
    @Test func destinationBadgesUseNativeOptionsAndFollowTabPlacement() async throws {
        let registrations = MobileFeatureRegistry.standard().registrations
        let root = BadgeTabPreview()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: root)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        let tabs = try #require(findTabs(controller))
        let isPad = controller.traitCollection.userInterfaceIdiom == .pad
        for sidebar in isPad ? [false, true] : [false] {
            tabs.sidebar.isHidden = !sidebar
            try await Task.sleep(for: .milliseconds(500))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            Attachment.record(try #require(image.pngData()), named: "workspace-destination-sidebar-\(sidebar).png")
            #expect(tabs.tabs.count == registrations.count)
            for (tab, feature) in zip(tabs.tabs, registrations) {
                let count = feature.id == .workspaces ? 3 : (feature.id == .assistant ? 12 : 0)
                #expect(tab.badgeValue == (count > 0 ? String(count) : nil))
            }
        }
    }

    private func findTabs(_ controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.lazy.compactMap { findTabs($0) }.first
    }

    private struct BadgeTabPreview: View {
        @State private var selection = MobileDestination.assistant

        var body: some View {
            TabView(selection: $selection) {
                ForEach(MobileFeatureRegistry.standard().registrations) { feature in
                    Tab(value: feature.id) {
                        Text(feature.title)
                    } label: {
                        Label(feature.title, systemImage: feature.symbol)
                    }
                    .badge(feature.id == .workspaces ? 3 : (feature.id == .assistant ? 12 : 0))
                }
            }.tabViewStyle(.sidebarAdaptable)
        }
    }

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
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "command-notifications-ios-\(language)-\(dark).png")
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

import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing
import UIKit

@testable import TermindIOS

@Suite(
    .requiresKeyWindow,
    .serialized)
@MainActor
struct MobileHostIntegrationRenderingTests {
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func iconPickerFollowsGroupAndOnlyChangesTheDraft(language: String) async throws {
        let draft = HostArtworkDraft()
        let controller = UIHostingController(
            rootView: Form {
                HostOrganizationSection(host: Binding(get: { draft.host }, set: { draft.host = $0 })) {
                    LabeledContent(AppStrings.Vault.group.swiftUIKey) { Text(verbatim: "Production") }
                } tagsField: {
                    Text(AppStrings.Vault.tags)
                }
            }.environment(\.locale, Locale(identifier: language)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        let picker = try #require(
            descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.showsMenuAsPrimaryAction })
        let actions = try await menuActions(in: picker, expectedCount: HostIconCatalog.bundled.entries.count + 2)
        #expect(
            actions.prefix(2).map(\.title) == [
                AppLocalization.string("Automatic", locale: Locale(identifier: language)),
                AppLocalization.string("Server", locale: Locale(identifier: language)),
            ])
        #expect(actions.dropFirst(2).map(\.title) == HostIconCatalog.bundled.selectableEntries.map(\.title))
        #expect(actions.first?.state == .on)
        picker.sendAction(try #require(actions.first { $0.title == "Windows" }))
        #expect(draft.host.iconOverrideID == "windows")
        #expect(draft.host.detectedDistribution?.id == "macos")
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(500))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let data = try #require(image.pngData())
            let name = "host-icons-mobile-\(language)-\(style.rawValue).png"
            Attachment.record(data, named: name)
            try data.write(to: FileManager.default.temporaryDirectory.appending(path: name))
        }
        let updated = try await menuActions(in: picker, expectedCount: actions.count)
        picker.sendAction(updated[0])
        #expect(draft.host.iconOverrideID == nil)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func integrationPickerKeepsItsDraftAtPhoneWidth(language: String) async throws {
        let draft = HostIntegrationDraft()
        let controller = UIHostingController(
            rootView: Form {
                Section("Group") { Text("Production") }
                HostIntegrationSection(mode: Binding(get: { draft.mode }, set: { draft.mode = $0 }))
            }
            .environment(\.locale, Locale(identifier: language)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 400)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.view.layoutIfNeeded()
        #expect(descendants(controller.view).compactMap { $0 as? UISegmentedControl }.isEmpty)
        let picker = try #require(
            descendants(controller.view).compactMap { $0 as? UIButton }.first { $0.showsMenuAsPrimaryAction })
        let labels = ["Default", "Enable", "Disable"].map {
            AppLocalization.string($0, locale: Locale(identifier: language))
        }
        let actions = try await menuActions(in: picker)
        #expect(actions.map(\.title) == labels)
        #expect(actions.map(\.state) == [.on, .off, .off])
        picker.sendAction(actions[1])
        #expect(draft.mode == .enabled)
        controller.view.frame.size.width = 600
        controller.view.layoutIfNeeded()
        let enabledActions = try await menuActions(in: picker)
        #expect(enabledActions.map(\.title) == labels)
        #expect(enabledActions.map(\.state) == [.off, .on, .off])
        picker.sendAction(enabledActions[2])
        #expect(draft.mode == .disabled)
        controller.view.frame.size.width = 375
        controller.view.layoutIfNeeded()
        let disabledActions = try await menuActions(in: picker)
        #expect(disabledActions.map(\.title) == labels)
        #expect(disabledActions.map(\.state) == [.off, .off, .on])
        picker.sendAction(disabledActions[0])
        #expect(draft.mode == .followGlobalSettings)
        try await Task.sleep(for: .milliseconds(300))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "host-integration-mobile-\(language).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "host-integration-mobile-\(language).png"))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func agentForwardingFollowsStartupSnippet(language: String) async throws {
        let controller = UIHostingController(
            rootView: Form {
                HostSessionSection(
                    charset: .constant(.utf8), sftpInitialPath: .constant(""),
                    agentForwardingEnabled: .constant(true))
            }.environment(\.locale, Locale(identifier: language)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 650)
        window.rootViewController = controller
        window.windowLevel = .alert + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        let toggle = try #require(descendants(controller.view).compactMap { $0 as? UISwitch }.first)
        #expect(toggle.isOn)
        let pickers = descendants(controller.view).compactMap { $0 as? UIButton }.filter { $0.showsMenuAsPrimaryAction }
        let startup = try #require(pickers.last)
        #expect(
            toggle.convert(toggle.bounds, to: controller.view).midY
                > startup.convert(startup.bounds, to: controller.view).midY)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let data = try #require(image.pngData())
        Attachment.record(data, named: "agent-forwarding-mobile-\(language).png")
        try data.write(
            to: FileManager.default.temporaryDirectory.appending(path: "agent-forwarding-mobile-\(language).png"))
    }

    private func descendants(_ view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func menuActions(in button: UIButton, expectedCount: Int = 3) async throws -> [UIAction] {
        button.performPrimaryAction()
        try await Task.sleep(for: .milliseconds(500))
        let interaction = try #require(button.contextMenuInteraction)
        var actions: [UIAction] = []
        interaction.updateVisibleMenu { menu in
            actions = self.menuActions(menu)
            return menu
        }
        interaction.dismissMenu()
        try await Task.sleep(for: .milliseconds(300))
        try #require(actions.count == expectedCount)
        return actions
    }

    private func menuActions(_ menu: UIMenu) -> [UIAction] {
        menu.children.flatMap { element -> [UIAction] in
            if let action = element as? UIAction { return [action] }
            if let submenu = element as? UIMenu { return menuActions(submenu) }
            return []
        }
    }
}

@Observable @MainActor private final class HostArtworkDraft {
    var host = TermindDomain.Host(
        name: "Mac", host: "example.invalid", detectedDistribution: DetectedDistribution(id: "macos"))
}

@Observable @MainActor private final class HostIntegrationDraft {
    var mode = HostShellIntegrationMode.followGlobalSettings
}

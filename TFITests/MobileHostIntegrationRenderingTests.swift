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
            rootView: HostArtworkForm(draft: draft).environment(\.locale, Locale(identifier: language)))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: min(scene.screen.bounds.width, 834), height: 600)
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
        let generalTitles = HostGeneralIcon.allCases.map {
            AppLocalization.string(String.LocalizationValue($0.title.key), locale: Locale(identifier: language))
        }
        let expectedGroups = [
            [AppLocalization.string("Automatic", locale: Locale(identifier: language))],
            generalTitles,
            HostIconCatalog.bundled.selectableEntries.map(\.title),
        ]
        let actions = try await menuActions(
            in: picker, expectedCount: HostIconCatalog.bundled.entries.count + generalTitles.count + 1,
            expectedGroups: expectedGroups)
        #expect(
            actions.prefix(2).map(\.title) == [
                AppLocalization.string("Automatic", locale: Locale(identifier: language)),
                AppLocalization.string("Server", locale: Locale(identifier: language)),
            ])
        #expect(Array(actions.dropFirst().prefix(generalTitles.count).map(\.title)) == generalTitles)
        #expect(
            actions.dropFirst(generalTitles.count + 1).map(\.title)
                == HostIconCatalog.bundled.selectableEntries.map(\.title))
        #expect(actions.allSatisfy { $0.image != nil })
        #expect(actions.first?.state == .on)
        #expect(actions.filter { $0.state == .on }.count == 1)
        let automaticImage = try imagePixels(actions.first?.image)
        try await captureIconPicker(window, language: language, name: "automatic")
        picker.sendAction(actions[2])
        #expect(draft.host.iconOverrideID == "cloud")
        #expect(draft.host.detectedDistribution?.id == "macos")
        let generalSelected = try await menuActions(in: picker, expectedCount: actions.count)
        #expect(generalSelected[2].state == .on)
        #expect(generalSelected.filter { $0.state == .on }.count == 1)
        #expect(try imagePixels(generalSelected[0].image) == automaticImage)
        try await captureIconPicker(window, language: language, name: "cloud")
        picker.sendAction(try #require(actions.first { $0.title == "Windows" }))
        #expect(draft.host.iconOverrideID == "windows")
        #expect(draft.host.detectedDistribution?.id == "macos")
        try await captureIconPicker(window, language: language, name: "windows")
        let updated = try await menuActions(in: picker, expectedCount: actions.count)
        picker.sendAction(updated[0])
        #expect(draft.host.iconOverrideID == nil)
        draft.host.detectedDistribution = nil
        let undetected = try await menuActions(in: picker, expectedCount: actions.count)
        #expect(try imagePixels(undetected[0].image) == imagePixels(undetected[1].image))
        #expect(try imagePixels(undetected[0].image) != automaticImage)
        try await captureIconPicker(window, language: language, name: "fallback")
        draft.host.iconOverrideID = "future-icon"
        let unknown = try await menuActions(in: picker, expectedCount: actions.count + 1)
        #expect(unknown.last?.title == AppLocalization.string("Unknown Icon", locale: Locale(identifier: language)))
        #expect(unknown.last?.state == .on)
        #expect(unknown.filter { $0.state == .on }.count == 1)
        #expect(try imagePixels(unknown.last?.image) == imagePixels(unknown[1].image))
        #expect(draft.host.iconOverrideID == "future-icon")
    }

    private func imagePixels(_ image: UIImage?) throws -> Data {
        let image = try #require(image)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        return renderer.pngData { _ in
            image.withTintColor(.black, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(x: 0, y: 0, width: 24, height: 24))
        }
    }

    private func captureIconPicker(_ window: UIWindow, language: String, name: String) async throws {
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                #expect(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
            }
            let data = try #require(image.pngData())
            let filename = "host-icons-mobile-\(language)-\(name)-\(Int(window.bounds.width))-\(style.rawValue).png"
            Attachment.record(data, named: filename)
            try data.write(to: FileManager.default.temporaryDirectory.appending(path: filename))
        }
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

    private func menuActions(
        in button: UIButton, expectedCount: Int = 3, expectedGroups: [[String]]? = nil
    ) async throws -> [UIAction] {
        button.performPrimaryAction()
        try await Task.sleep(for: .milliseconds(500))
        let interaction = try #require(button.contextMenuInteraction)
        var actions: [UIAction] = []
        interaction.updateVisibleMenu { menu in
            actions = self.menuActions(menu)
            if let expectedGroups {
                #expect(self.actionGroups(menu) == expectedGroups)
            }
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

    private func actionGroups(_ menu: UIMenu) -> [[String]] {
        let actions = menu.children.compactMap { $0 as? UIAction }
        if !actions.isEmpty { return [actions.map(\.title)] }
        return menu.children.compactMap { $0 as? UIMenu }.flatMap(actionGroups)
    }
}

@Observable @MainActor private final class HostArtworkDraft {
    var host = TermindDomain.Host(
        name: "Mac", host: "example.invalid", detectedDistribution: DetectedDistribution(id: "macos"))
}

private struct HostArtworkForm: View {
    @Bindable var draft: HostArtworkDraft

    var body: some View {
        Form {
            HostOrganizationSection(host: $draft.host, detectedDistribution: draft.host.detectedDistribution) {
                LabeledContent(AppStrings.Vault.group.swiftUIKey) { Text(verbatim: "Production") }
            } tagsField: {
                Text(AppStrings.Vault.tags)
            }
        }
    }
}

@Observable @MainActor private final class HostIntegrationDraft {
    var mode = HostShellIntegrationMode.followGlobalSettings
}

import Foundation
import SwiftUI
import TermindApplication
import TermindPresentation
import Testing

@testable import Termind

struct PresentationCopyTests {
    @MainActor
    @Test
    func nativeMenusResolveResourcesWhenBuiltIncludingNestedMenus() {
        let entries = [
            NativeMenuEntry(
                title: AppStrings.Navigation.settings,
                children: [
                    NativeMenuEntry(title: AppStrings.Common.cancel),
                    NativeMenuEntry(title: String("Custom server")),
                ])
        ]
        for language in ["en", "ja", "zh-Hans", "zh-Hant"] {
            let locale = Locale(identifier: language)
            let menu = NativeMenuEntry.menu(entries, locale: locale)
            #expect(
                menu.items.first?.title
                    == AppLocalization.resolve(AppStrings.Navigation.settings, locale: locale))
            #expect(
                menu.items.first?.submenu?.items.first?.title
                    == AppLocalization.resolve(AppStrings.Common.cancel, locale: locale))
            #expect(menu.items.first?.submenu?.items.last?.title == "Custom server")
        }
    }

    @Test(arguments: ["en", "ja", "zh-Hans", "zh-Hant"], [0, 1, 7])
    func fileDeletionKeepsLiteralPathsAndLocalizesItsRemainder(language: String, remaining: Int) {
        let locale = Locale(identifier: language)
        let title = AppLocalization.resolve(AppStrings.SFTP.deleteConfirmation("file.txt"), locale: locale)
        let paths = "/home/example/file\n/home/example/[draft]"
        let message = AppStrings.SFTP.deletionMessage(
            paths: paths, remainingCount: remaining, locale: locale)
        #expect(title.contains("file.txt"))
        #expect(!title.contains("NSLanguage"))
        #expect(message.hasPrefix(paths))
        if remaining > 0 {
            #expect(
                message.contains(
                    AppLocalization.resolve(
                        AppStrings.SFTP.remainingDeletionItems(remaining),
                        locale: Locale(identifier: language))))
        } else {
            #expect(message.hasPrefix(paths + "\n\n"))
        }
        #expect(!message.contains("%"))
        #expect(!message.contains("NSLanguage"))
    }

    /// Only the values actually configured may surface; a missing model or
    /// effort must not leave a dangling separator in the composed copy.
    @Test
    func modelAccessibilityOnlyIncludesAvailableConfiguration() {
        let locale = Locale(identifier: "en")
        #expect(
            AppStrings.Assistant.modelSummary(modelName: "Example", effortName: nil, locale: locale)
                == "Example")
        #expect(
            AppStrings.Assistant.modelSummary(modelName: nil, effortName: "High", locale: locale)
                == AppLocalization.resolve(AppStrings.Assistant.noModel, locale: locale))
        #expect(
            AppStrings.Assistant.modelHelp(modelName: nil, providerName: nil, effortName: "High")
                == AppStrings.Assistant.noModelConfigured)
        let help = AppLocalization.resolve(
            AppStrings.Assistant.modelHelp(modelName: "Example", providerName: "Provider", effortName: nil),
            locale: locale)
        #expect(help.contains("Example") && help.contains("Provider") && !help.contains("High"))
        let missing = AppLocalization.resolve(
            AppStrings.Assistant.modelAccessibilityLabel(modelName: nil, effortName: "High"), locale: locale)
        #expect(!missing.contains("High"))
    }

    @Test
    func oneResourceCanResolveDifferentAppLanguagesWithoutCaching() {
        let resource = AppStrings.Navigation.settings
        let simplified = AppLocalization.resolve(resource, locale: Locale(identifier: "zh-Hans"))
        let english = AppLocalization.resolve(resource, locale: Locale(identifier: "en"))
        let traditional = AppLocalization.resolve(resource, locale: Locale(identifier: "zh-Hant"))
        #expect(Set([simplified, english, traditional]).count == 3)
        let editorTitle = IdentityEditorConfiguration.standard.newTitle
        #expect(
            AppLocalization.resolve(editorTitle, locale: Locale(identifier: "zh-Hans"))
                == AppLocalization.resolve(AppStrings.Keychain.newIdentity, locale: Locale(identifier: "zh-Hans")))
    }

    @MainActor
    @Test(arguments: ["en", "ja", "zh-Hans", "zh-Hant"])
    func swiftUIResourceBridgePreservesEnvironmentLanguageAndMarkdown(language: String) throws {
        let locale = Locale(identifier: language)
        let resource = AppStrings.Settings.terminalConfigurationExplanation
        let expected = try pixels(Text(resource), locale: locale)
        #expect(try pixels(Text(resource.swiftUIKey), locale: locale) == expected)
        #expect(
            try pixels(Text(AppStrings.Common.cancel.swiftUIKey), locale: locale)
                == pixels(Text(AppStrings.Common.cancel), locale: locale))
        #expect(
            try pixels(Text(AppStrings.Navigation.settings.swiftUIKey), locale: locale)
                == pixels(Text(AppStrings.Navigation.settings), locale: locale))
    }

    @MainActor
    private func pixels(_ text: Text, locale: Locale) throws -> Data {
        let renderer = ImageRenderer(
            content: text.font(.system(size: 14)).foregroundStyle(.black)
                .frame(width: 360).fixedSize(horizontal: false, vertical: true)
                .environment(\.locale, locale).environment(\.colorScheme, .light))
        let image = try #require(renderer.cgImage)
        return try #require(image.dataProvider?.data) as Data
    }
}

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
        for language in ["en", "zh-Hans", "zh-Hant"] {
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

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 7])
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

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func singleFileDeletionWarningDoesNotRepeatTheTitlePath(language: String) {
        let locale = Locale(identifier: language)
        let warning = AppLocalization.resolve(AppStrings.SFTP.recursiveDeletionWarning, locale: locale)
        #expect(!warning.contains("/home/example/file.txt"))
        #expect(!warning.contains("NSLanguage"))
        #expect(!warning.isEmpty)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 2])
    func groupDeletionUsesTheRequestedLanguageAndPreservesPluralRules(language: String, count: Int) {
        let locale = Locale(identifier: language)
        let withoutGroups = AppStrings.Vault.groupDeletionMessage(
            hostCount: count, nestedGroupCount: 0, locale: locale)
        let withGroups = AppStrings.Vault.groupDeletionMessage(
            hostCount: count, nestedGroupCount: count, locale: locale)
        let hosts = AppLocalization.resolve(AppStrings.Vault.hostCount(count), locale: locale)
        #expect(
            withoutGroups
                == AppLocalization.resolve(AppStrings.Vault.groupContainsHosts(hosts), locale: locale))
        if count == 0 {
            #expect(withGroups == withoutGroups)
        } else {
            let groups = AppLocalization.resolve(
                count == 1
                    ? AppStrings.Vault.oneNestedGroup
                    : AppStrings.Vault.nestedGroupCount(count),
                locale: locale)
            #expect(
                withGroups
                    == AppLocalization.resolve(
                        AppStrings.Vault.groupContainsHostsAndGroups(hosts: hosts, groups: groups), locale: locale))
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func snippetCountsKeepZeroSingularAndPluralMeanings(language: String) {
        let locale = Locale(identifier: language)
        for count in 0...2 {
            let summary = AppLocalization.resolve(AppStrings.Snippets.targetSummary(count: count), locale: locale)
            let expectedSummaryResource: LocalizedStringResource
            switch count {
            case 0:
                expectedSummaryResource = AppStrings.Snippets.noTargets
            case 1:
                expectedSummaryResource = AppStrings.Snippets.oneTarget
            default:
                expectedSummaryResource = AppStrings.Snippets.targetCount(count)
            }
            #expect(
                summary
                    == AppLocalization.resolve(expectedSummaryResource, locale: locale))
            let message = AppLocalization.resolve(
                AppStrings.Snippets.packageDeletionMessage(snippetCount: count), locale: locale)
            #expect(
                message
                    == AppLocalization.resolve(
                        count == 1
                            ? AppStrings.Snippets.packageContainsOneSnippet
                            : AppStrings.Snippets.packageContainsSnippets(count),
                        locale: locale))
            #expect(!message.contains("%"))
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func modelAccessibilityOnlyIncludesAvailableConfiguration(language: String) {
        let locale = Locale(identifier: language)
        #expect(
            AppStrings.Assistant.modelSummary(modelName: "Settings", effortName: nil, locale: locale) == "Settings")
        #expect(
            AppStrings.Assistant.modelSummary(modelName: "Example", effortName: "High", locale: locale)
                == "Example · High")
        #expect(
            AppStrings.Assistant.modelSummary(modelName: nil, effortName: "High", locale: locale)
                == AppLocalization.resolve(AppStrings.Assistant.noModel, locale: locale))
        let unavailableHelp = AppStrings.Assistant.modelHelp(modelName: nil, providerName: nil, effortName: "High")
        #expect(unavailableHelp == AppStrings.Assistant.noModelConfigured)
        let help = AppLocalization.resolve(
            AppStrings.Assistant.modelHelp(modelName: "Example", providerName: "Provider", effortName: nil),
            locale: locale)
        #expect(help.contains("Example") && help.contains("Provider") && !help.contains("High"))
        let reasoningHelp = AppLocalization.resolve(
            AppStrings.Assistant.modelHelp(modelName: "Example", providerName: "Provider", effortName: "High"),
            locale: locale)
        #expect(
            reasoningHelp.contains("Example") && reasoningHelp.contains("Provider") && reasoningHelp.contains("High"))
        let missing = AppStrings.Assistant.modelAccessibilityLabel(modelName: nil, effortName: "High")
        let model = AppStrings.Assistant.modelAccessibilityLabel(modelName: "Example", effortName: nil)
        let reasoning = AppStrings.Assistant.modelAccessibilityLabel(modelName: "Example", effortName: "High")
        #expect(!AppLocalization.resolve(missing, locale: locale).contains("High"))
        #expect(AppLocalization.resolve(model, locale: locale).contains("Example"))
        #expect(!AppLocalization.resolve(model, locale: locale).contains("High"))
        #expect(AppLocalization.resolve(reasoning, locale: locale).contains("Example"))
        #expect(AppLocalization.resolve(reasoning, locale: locale).contains("High"))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 2])
    func transferConflictsKeepTheirCount(language: String, count: Int) {
        let message = AppLocalization.resolve(
            AppStrings.SFTP.existingItemsMessage(count: count), locale: Locale(identifier: language))
        #expect(
            message
                == AppLocalization.resolve(
                    count == 1
                        ? AppStrings.SFTP.oneExistingItem
                        : AppStrings.SFTP.existingItemCount(count),
                    locale: Locale(identifier: language)))
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
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
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

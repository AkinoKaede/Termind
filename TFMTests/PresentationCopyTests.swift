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
                title: TermindCopy.Navigation.settings,
                children: [
                    NativeMenuEntry(title: TermindCopy.Common.cancel),
                    NativeMenuEntry(title: String("Custom server")),
                ])
        ]
        for (language, title, child) in [
            ("en", "Settings", "Cancel"), ("zh-Hans", "设置", "取消"), ("zh-Hant", "設定", "取消"),
        ] {
            let menu = NativeMenuEntry.menu(entries, locale: Locale(identifier: language))
            #expect(menu.items.first?.title == title)
            #expect(menu.items.first?.submenu?.items.first?.title == child)
            #expect(menu.items.first?.submenu?.items.last?.title == "Custom server")
        }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 7])
    func fileDeletionKeepsLiteralPathsAndLocalizesItsRemainder(language: String, remaining: Int) {
        let paths = "/home/example/file\n/home/example/[draft]"
        let message = TermindCopy.SFTP.deletionMessage(
            paths: paths, remainingCount: remaining, locale: Locale(identifier: language))
        #expect(message.hasPrefix(paths))
        if remaining > 0 {
            let suffix =
                language == "en" ? "and \(remaining) more" : "另有\(remaining)" + (language == "zh-Hans" ? "项" : "項")
            #expect(message.contains(suffix))
        } else {
            #expect(message.hasPrefix(paths + "\n\n"))
        }
        #expect(!message.contains("%"))
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 2])
    func groupDeletionUsesTheRequestedLanguageAndPreservesPluralRules(language: String, count: Int) {
        let locale = Locale(identifier: language)
        let withoutGroups = TermindCopy.Vault.groupDeletionMessage(
            hostCount: count, nestedGroupCount: 0, locale: locale)
        let withGroups = TermindCopy.Vault.groupDeletionMessage(
            hostCount: count, nestedGroupCount: count, locale: locale)
        switch language {
        case "zh-Hans":
            #expect(withoutGroups == "此组包含\(count)台主机。")
            if count > 0 { #expect(withGroups == "此组包含\(count)台主机和\(count)个子组。将删除嵌入组。") }
        case "zh-Hant":
            #expect(withoutGroups == "此組包含\(count)台主機。")
            if count > 0 { #expect(withGroups == "此組包含\(count)台主機和\(count)個子組。將刪除嵌入組。") }
        default:
            let hosts = count == 1 ? "1 host" : "\(count) hosts"
            #expect(withoutGroups == "This group contains \(hosts).")
            if count > 0 {
                let groups = count == 1 ? "1 nested group" : "\(count) nested groups"
                #expect(withGroups == "This group contains \(hosts) and \(groups). Nested groups will be deleted.")
            }
        }
        if count == 0 { #expect(withGroups == withoutGroups) }
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func snippetCountsKeepZeroSingularAndPluralMeanings(language: String) {
        let locale = Locale(identifier: language)
        let expected: [String] =
            switch language {
            case "zh-Hans": ["无目标", "1个目标", "2目标"]
            case "zh-Hant": ["無目標", "1個目標", "2目標"]
            default: ["No targets", "1 target", "2 targets"]
            }
        for count in 0...2 {
            #expect(
                AppLocalization.resolve(TermindCopy.Snippets.targetSummary(count: count), locale: locale)
                    == expected[count])
            let message = AppLocalization.resolve(
                TermindCopy.Snippets.packageDeletionMessage(snippetCount: count), locale: locale)
            #expect(message.contains(String(count)))
            #expect(!message.contains("%"))
        }
        #expect(TermindCopy.Snippets.packageDeletionMessage(snippetCount: 1).key == "This package contains 1 snippet.")
        #expect(
            TermindCopy.Snippets.packageDeletionMessage(snippetCount: 0).key
                == "This package tree contains %lld snippets.")
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func modelAccessibilityOnlyIncludesAvailableConfiguration(language: String) {
        let locale = Locale(identifier: language)
        #expect(
            TermindCopy.Assistant.modelSummary(modelName: "Settings", effortName: nil, locale: locale) == "Settings")
        #expect(
            TermindCopy.Assistant.modelSummary(modelName: "Example", effortName: "High", locale: locale)
                == "Example · High")
        #expect(
            TermindCopy.Assistant.modelSummary(modelName: nil, effortName: "High", locale: locale)
                == AppLocalization.resolve(TermindCopy.Assistant.noModel, locale: locale))
        let unavailableHelp = TermindCopy.Assistant.modelHelp(modelName: nil, providerName: nil, effortName: "High")
        #expect(unavailableHelp == TermindCopy.Assistant.noModelConfigured)
        let help = AppLocalization.resolve(
            TermindCopy.Assistant.modelHelp(modelName: "Example", providerName: "Provider", effortName: nil),
            locale: locale)
        #expect(help.contains("Example") && help.contains("Provider") && !help.contains("High"))
        let reasoningHelp = AppLocalization.resolve(
            TermindCopy.Assistant.modelHelp(modelName: "Example", providerName: "Provider", effortName: "High"),
            locale: locale)
        #expect(
            reasoningHelp.contains("Example") && reasoningHelp.contains("Provider") && reasoningHelp.contains("High"))
        let missing = TermindCopy.Assistant.modelAccessibilityLabel(modelName: nil, effortName: "High")
        let model = TermindCopy.Assistant.modelAccessibilityLabel(modelName: "Example", effortName: nil)
        let reasoning = TermindCopy.Assistant.modelAccessibilityLabel(modelName: "Example", effortName: "High")
        #expect(!AppLocalization.resolve(missing, locale: locale).contains("High"))
        #expect(AppLocalization.resolve(model, locale: locale).contains("Example"))
        #expect(!AppLocalization.resolve(model, locale: locale).contains("High"))
        let expected: String =
            switch language {
            case "zh-Hans": "模型Example，推理强度High"
            case "zh-Hant": "模型Example，推理強度High"
            default: "Model Example, effort High"
            }
        #expect(AppLocalization.resolve(reasoning, locale: locale) == expected)
    }

    @Test(arguments: ["en", "zh-Hans", "zh-Hant"], [0, 1, 2])
    func transferConflictsKeepTheirCount(language: String, count: Int) {
        let message = AppLocalization.resolve(
            TermindCopy.SFTP.existingItemsMessage(count: count), locale: Locale(identifier: language))
        let expected: String =
            switch language {
            case "zh-Hans": "\(count)项已存在"
            case "zh-Hant": "\(count)項已存在"
            default: count == 1 ? "1 item already exists" : "\(count) items already exist"
            }
        #expect(message == expected)
    }

    @Test
    func oneResourceCanResolveDifferentAppLanguagesWithoutCaching() {
        let resource = TermindCopy.Navigation.settings
        #expect(AppLocalization.resolve(resource, locale: Locale(identifier: "zh-Hans")) == "设置")
        #expect(AppLocalization.resolve(resource, locale: Locale(identifier: "en")) == "Settings")
        #expect(AppLocalization.resolve(resource, locale: Locale(identifier: "zh-Hant")) == "設定")
        let editorTitle = IdentityEditorConfiguration.standard.newTitle
        #expect(AppLocalization.resolve(editorTitle, locale: Locale(identifier: "en")) == "New Identity")
        #expect(
            AppLocalization.resolve(editorTitle, locale: Locale(identifier: "zh-Hans"))
                == AppLocalization.resolve(TermindCopy.Keychain.newIdentity, locale: Locale(identifier: "zh-Hans")))
    }

    @MainActor
    @Test(arguments: ["en", "zh-Hans", "zh-Hant"])
    func swiftUIResourceBridgePreservesEnvironmentLanguageAndMarkdown(language: String) throws {
        let locale = Locale(identifier: language)
        let resource = TermindCopy.Settings.terminalConfigurationExplanation
        let original: LocalizedStringKey =
            "Termind uses [Ghostty](https://ghostty.org) as its terminal engine. Custom configuration uses [Ghostty's configuration format](https://ghostty.org/docs/config/reference)."
        let expected = try pixels(Text(original), locale: locale)
        #expect(try pixels(Text(resource), locale: locale) == expected)
        #expect(try pixels(Text(resource.swiftUIKey), locale: locale) == expected)
        // Compare the original localized rendering, including its font language
        // metadata, rather than rendering a translated string as verbatim text.
        #expect(
            try pixels(Text(TermindCopy.Common.cancel.swiftUIKey), locale: locale)
                == pixels(Text("Cancel"), locale: locale))
        #expect(
            try pixels(Text(TermindCopy.Navigation.settings.swiftUIKey), locale: locale)
                == pixels(Text("Settings"), locale: locale))
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

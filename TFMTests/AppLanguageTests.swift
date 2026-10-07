import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

struct AppLanguageTests {
    @Test
    func missingAndUnknownPreferencesFollowSystem() throws {
        let defaults = try makeDefaults()
        #expect(AppLanguage.stored(in: defaults) == .system)

        defaults.set("unsupported", forKey: SettingsKey.appLanguage)
        #expect(AppLanguage.stored(in: defaults) == .system)
    }

    @Test
    func explicitLanguagesWriteCanonicalLanguageTags() throws {
        let defaults = try makeDefaults()

        AppLanguage.store(.english, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .english)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        AppLanguage.store(.japanese, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .japanese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["ja"])
        #expect(AppLanguage.japanese.locale.identifier == "ja")
        #expect(AppLanguage.japanese.displayName == "日本語")

        AppLanguage.store(.simplifiedChinese, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
        #expect(AppLanguage.simplifiedChinese.locale.identifier == "zh-Hans")
        #expect(AppLanguage.simplifiedChinese.displayName == "简体中文")

        AppLanguage.store(.traditionalChinese, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .traditionalChinese)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hant"])
        #expect(AppLanguage.traditionalChinese.locale.identifier == "zh-Hant")
        #expect(AppLanguage.traditionalChinese.displayName == "繁體中文")
    }

    @Test(arguments: ["zh-Hans-CN", "zh-CN", "zh_CN", "zh-Hans-SG", "zh"])
    func legacySimplifiedChinesePreferencesMigrateToCanonicalTag(identifier: String) throws {
        let defaults = try makeDefaults()
        defaults.set(identifier, forKey: SettingsKey.appLanguage)
        defaults.set([identifier], forKey: "AppleLanguages")

        #expect(AppLanguage.stored(in: defaults) == .simplifiedChinese)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == "zh-Hans")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans"])
    }

    @Test(arguments: ["zh-TW", "zh-Hant-TW", "zh-HK", "zh-MO", "unsupported"])
    func unknownPreferencesContinueToFollowSystemWithoutMigration(identifier: String) throws {
        let defaults = try makeDefaults()
        defaults.set(identifier, forKey: SettingsKey.appLanguage)

        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.string(forKey: SettingsKey.appLanguage) == identifier)
    }

    @Test
    func traditionalChineseDisplayNameRequiresTaiwanRegionAndVisibleFlag() {
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: true)
                == "正體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: false)
                == "繁體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: "HK", canDisplayTaiwanFlag: true)
                == "繁體中文")
        #expect(
            AppLanguage.traditionalChinese.displayName(deviceRegion: nil, canDisplayTaiwanFlag: false)
                == "繁體中文")
        #expect(AppLanguage.english.displayName(deviceRegion: "TW", canDisplayTaiwanFlag: true) == "English")
    }

    @Test(arguments: ["zh-TW", "zh-Hant-TW", "zh-HK", "zh-MO"])
    func traditionalChineseSystemLocalesResolveTraditionalCatalog(identifier: String) {
        #expect(AppLocalization.string("Settings", locale: Locale(identifier: identifier)) == "設定")
    }

    @Test
    func simplifiedAndTraditionalChineseCatalogsDoNotCrossFallback() {
        #expect(AppLocalization.string("Settings", locale: Locale(identifier: "zh-Hans")) == "设置")
        #expect(AppLocalization.string("Settings", locale: Locale(identifier: "zh-Hant")) == "設定")
    }

    @Test(arguments: ["ja", "ja-JP", "ja_JP"])
    func japaneseLocalesResolveAppCopyAndPreserveInterpolations(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(AppLocalization.string("Settings", locale: locale) == "設定")
        #expect(AppLocalization.resolve(AppStrings.Common.cancel, locale: locale) == "キャンセル")
        let host = "web-01"
        let command = "uptime"
        #expect(
            AppLocalization.string("Ran “\(command)” on \(host)", locale: locale)
                == "web-01で「uptime」を実行しました")
        #expect(AppLocalization.string("\(3) files", locale: locale) == "3個のファイル")
    }

    @Test(arguments: [("zh-Hans", "词元"), ("zh-Hant", "符元")])
    func assistantTokenCountsUseModelTerminology(language: String, unit: String) {
        let locale = Locale(identifier: language)
        let prefix = "≈"
        let count = "1.2k"
        #expect(AppLocalization.string("\(prefix)\(count) tokens", locale: locale) == "≈1.2k\(unit)")
        for key: String.LocalizationValue in ["Token", "Bearer Token", "Clear Token", "Generate Token"] {
            #expect(!AppLocalization.string(key, locale: locale).contains(unit))
        }
    }

    @Test
    func followSystemRemovesAppleLanguageOverride() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(["zh-Hans"], forKey: "AppleLanguages")

        AppLanguage.store(.system, in: defaults)

        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
    }

    @Test
    func forwardingTemplatesPreserveArgumentsInOrder() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "Frameworks/Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let interpolations: [String: [String]] = [
            "SSH %@ → This Mac %@": ["[::1]:8080", "[2001:db8::1]:443"],
            "Unable to listen on %@: %@": ["[::1]:8080", "Address already in use"],
        ]

        for (key, arguments) in interpolations.sorted(by: { $0.key < $1.key }) {
            let entry = try #require(strings[key] as? [String: Any], "Missing forwarding template: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["ja", "zh-Hans", "zh-Hant"] {
                let localization = try #require(localizations[language] as? [String: Any])
                let unit = try #require(localization["stringUnit"] as? [String: Any])
                let translation = try #require(unit["value"] as? String)
                let placeholders = translation.matches(of: /%(?:[1-9][0-9]*\$)?@/)
                #expect(placeholders.count == arguments.count, "Placeholder mismatch: \(language) \(key)")
                let rendered = String(format: translation, arguments: arguments)
                var remaining = rendered[...]
                for argument in arguments {
                    let range = try #require(remaining.range(of: argument), "Lost value: \(language) \(key)")
                    remaining = remaining[range.upperBound...]
                }
            }
        }
    }

    @Test
    func countedToolResourcesUseCatalogPluralRules() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "Frameworks/Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])

        for key in [
            // `%lld results` is not here: `web_search`'s card moved to AgentKit
            // with the runtime, and so did the plural resource behind it.
            "%lld commands", "%lld hosts", "%lld items", "%lld questions",
            "%lld files", "%lld directories", "%lld scratch files", "%lld scratch items",
            "%lld URLs", "%lld plans", "%lld secrets", "%lld suggestions",
            "the task list %lld times",
            "%lld tool calls", "%@ — %lld tools",
        ] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])
            #expect(pluralForms(in: english).keys.sorted() == ["one", "other"])
            for language in ["ja", "zh-Hans", "zh-Hant"] {
                let localization = try #require(localizations[language] as? [String: Any])
                #expect(pluralForms(in: localization).keys.sorted() == ["other"])
            }
        }
    }

    @Test
    func taiwanFlagColorDetectionHandlesColorGrayscaleAndMissingPixels() {
        #expect(DeviceCensorship.containsColoredPixel([255, 0, 0, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([128, 128, 128, 255]))
        #expect(!DeviceCensorship.containsColoredPixel([]))
    }

    private func pluralForms(in localization: [String: Any]) -> [String: Any] {
        let variations = localization["variations"] as? [String: Any]
        return variations?["plural"] as? [String: Any] ?? [:]
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

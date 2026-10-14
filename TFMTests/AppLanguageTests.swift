import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import Testing

@testable import Termind

struct AppLanguageTests {
    @Test(arguments: [
        ("en", "SSH authentication failed: key detail; password detail"),
        ("zh-Hans", "SSH认证失败：key detail；password detail"),
        ("zh-Hant", "SSH認證失敗：key detail；password detail"),
        ("ja", "SSH認証に失敗しました：key detail；password detail"),
        ("de", "SSH-Authentifizierung fehlgeschlagen: key detail; password detail"),
        ("fr", "Échec de l’authentification SSH\u{00A0}: key detail; password detail"),
        ("ko", "SSH 인증 실패: key detail; password detail"),
    ])
    func authenticationFailuresUseOneLocalizedPrefixAndSemicolon(language: String, expected: String) {
        let locale = Locale(identifier: language)
        let separator = AppLocalization.resolve(AppStrings.Connections.authenticationFailureSeparator, locale: locale)
        let details = ["key detail", "password detail"].joined(separator: separator)
        #expect(
            AppLocalization.resolve(AppStrings.Connections.sshAuthenticationFailed(details), locale: locale) == expected
        )
    }

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

    @Test(arguments: [
        (AppLanguage.german, "de", "Deutsch"),
        (.french, "fr", "Français"),
        (.korean, "ko", "한국어"),
    ])
    func additionalLanguageChoicesPersistAndRestoreSystemNegotiation(
        language: AppLanguage, tag: String, name: String
    ) throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(AppLanguage.allCases.contains(language))
        #expect(language.displayName == name)
        #expect(language.locale.language.languageCode?.identifier == tag)
        AppLanguage.store(language, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == language)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == [tag])
        AppLanguage.store(.system, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
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

    @Test(arguments: [
        (AppLanguage.english, "The new language will be used after Termind relaunches."),
        (.japanese, "新しい言語はTermindの再起動後に適用されます。"),
        (.german, "Die neue Sprache wird nach dem Neustart von Termind verwendet."),
        (.french, "La nouvelle langue sera utilisée après le redémarrage de Termind."),
        (.korean, "새 언어는 Termind를 다시 실행한 후 적용됩니다."),
        (.simplifiedChinese, "重新启动Termind后将使用新语言。"),
        (.traditionalChinese, "重新啟動Termind後將使用新語言。"),
    ])
    func languageChangeNoticeUsesTheSelectedLanguage(language: AppLanguage, expected: String) {
        #expect(
            AppLocalization.resolve(
                AppStrings.Settings.theNewLanguageWillBeUsedAfterTermindRelaunches,
                locale: language.locale) == expected)
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

    @Test(arguments: ["de", "de-DE", "de-AT", "de_CH"])
    func germanLocalesResolveCopyAndReorderedArguments(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(AppLocalization.string("Settings", locale: locale) == "Einstellungen")
        #expect(AppLocalization.resolve(AppStrings.Common.cancel, locale: locale) == "Abbrechen")
        let duration = "2 s"
        #expect(
            AppLocalization.string("Command failed with exit code \(7) after \(duration).", locale: locale)
                == "Befehl nach 2 s mit Exit-Code 7 fehlgeschlagen."
        )
        #expect(AppLocalization.string("Memory", locale: locale) == "Arbeitsspeicher")
        #expect(AppLocalization.string("memory", locale: locale) == "Erinnerungen")
    }

    @Test(arguments: ["fr", "fr-FR", "fr-CA", "fr_BE"])
    func frenchLocalesResolveCopyAndPreserveCommandAndHost(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(AppLocalization.string("Settings", locale: locale) == "Réglages")
        #expect(AppLocalization.resolve(AppStrings.Common.cancel, locale: locale) == "Annuler")
        let command = "uptime"
        let host = "web-01"
        #expect(
            AppLocalization.string("Ran “\(command)” on \(host)", locale: locale)
                == "«\u{00A0}uptime\u{00A0}» exécuté sur web-01"
        )
        let count = "1.2k"
        let prefix = "≈"
        #expect(AppLocalization.string("\(prefix)\(count) tokens", locale: locale) == "≈1.2k tokens")
        #expect(AppLocalization.string("Bearer Token", locale: locale) == "Jeton Bearer")
    }

    @Test(arguments: ["ko", "ko-KR", "ko_KR"])
    func koreanLocalesResolveCopyAndReorderCommandArguments(identifier: String) {
        let locale = Locale(identifier: identifier)
        #expect(AppLocalization.string("Settings", locale: locale) == "설정")
        #expect(AppLocalization.resolve(AppStrings.Common.cancel, locale: locale) == "취소")
        let command = "uptime"
        let host = "web-01"
        #expect(
            AppLocalization.string("Ran “\(command)” on \(host)", locale: locale)
                == "web-01에서 ‘uptime’ 실행됨")
        let duration = "2 s"
        #expect(
            AppLocalization.string("Command failed with exit code \(7) after \(duration).", locale: locale)
                == "명령이 2 s 후 종료 코드 7로 실패했습니다.")
    }

    @Test(arguments: [
        ("Memory", "메모리"), ("memory", "기억"),
        ("Identity", "인증 프로필"), ("Credential", "자격 증명"),
        ("Password", "암호"), ("Passphrase", "암호 구문"),
        ("Export and Attach", "내보내고 호스트에 연결"),
        ("Discouraged", "사용자 확인 요청 안 함"),
    ])
    func koreanTermsReflectTheirProductContext(key: String, expected: String) throws {
        let path = try #require(Bundle.main.path(forResource: "ko", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == expected)
    }

    @Test(arguments: ["Google", "OpenAI", "사용자 모델"])
    func koreanDynamicLabelsDoNotAssumeTheFinalConsonantOfAProviderName(provider: String) {
        let locale = Locale(identifier: "ko")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.modelHelp(modelName: "model-01", providerName: provider, effortName: nil),
                locale: locale
            ) == "model-01 · 제공업체: \(provider)")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.modelHelp(modelName: "model-01", providerName: provider, effortName: "높음"),
                locale: locale
            ) == "model-01 · 제공업체: \(provider) · 추론 강도: 높음")
        #expect(
            AppLocalization.resolve(
                AppStrings.Assistant.compactionSummary(summarized: "2,000 토큰", retained: "500 토큰"),
                locale: locale
            ) == "압축됨 — 2,000 토큰 → 500 토큰")
    }

    @Test(arguments: [
        ("de", "Export and Attach", "Exportieren und zuordnen"),
        ("fr", "Export and Attach", "Exporter et associer"),
        ("de", "Retry Attachment", "Zuordnung erneut versuchen"),
        ("fr", "Retry Attachment", "Réessayer l’association"),
        ("de", "Discouraged", "Benutzerverifizierung nicht anfordern"),
        ("fr", "Discouraged", "Ne pas demander de vérification"),
    ])
    func europeanKeySettingsDistinguishAssociationFromFileAttachments(
        language: String, key: String, expected: String
    ) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: key, value: nil, table: nil) == expected)
    }

    @Test(arguments: [
        ("de", 0, "0 Dateien"), ("de", 1, "1 Datei"), ("de", 2, "2 Dateien"),
        ("fr", 0, "0 fichier"), ("fr", 1, "1 fichier"), ("fr", 2, "2 fichiers"),
        ("ko", 0, "파일 0개"), ("ko", 1, "파일 1개"), ("ko", 2, "파일 2개"),
    ])
    func countedResourcesUseCompiledPluralRules(language: String, count: Int, expected: String) {
        #expect(AppLocalization.string("\(count) files", locale: Locale(identifier: language)) == expected)
    }

    @Test(arguments: [("de", "Verbinden"), ("fr", "Se connecter"), ("ko", "연결")])
    func additionalBundleMetadataIsLocalized(language: String, expected: String) throws {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(
            bundle.localizedString(forKey: "QUICK_ACTION_CONNECT_TITLE", value: nil, table: "InfoPlist") == expected
        )
        #expect(bundle.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist") == "Termind")
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
            for language in ["de", "fr", "ja", "ko", "zh-Hans", "zh-Hant"] {
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
            for language in ["de", "fr"] {
                let localization = try #require(localizations[language] as? [String: Any])
                #expect(pluralForms(in: localization).keys.sorted() == ["one", "other"])
            }
            for language in ["ja", "ko", "zh-Hans", "zh-Hant"] {
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

import Foundation
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
    func explicitLanguagesWriteFullAppleLanguageTags() throws {
        let defaults = try makeDefaults()

        AppLanguage.store(.english, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .english)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["en"])

        AppLanguage.store(.simplifiedChineseChina, in: defaults)
        #expect(AppLanguage.stored(in: defaults) == .simplifiedChineseChina)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["zh-Hans-CN"])
        #expect(AppLanguage.simplifiedChineseChina.locale.identifier == "zh-Hans-CN")
    }

    @Test
    func followSystemRemovesAppleLanguageOverride() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(["zh-Hans-SG"], forKey: "AppleLanguages")

        AppLanguage.store(.system, in: defaults)

        #expect(AppLanguage.stored(in: defaults) == .system)
        #expect(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
    }

    @Test
    func everyCatalogEntryHasSimplifiedChinese() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Localizable", "InfoPlist"] {
            let url = repository.appending(path: "Termind/Resources/\(name).xcstrings")
            let root = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: url))
                    as? [String: Any]
            )
            let strings = try #require(root["strings"] as? [String: Any])
            for (key, value) in strings {
                let entry = try #require(value as? [String: Any])
                if entry["shouldTranslate"] as? Bool == false { continue }
                let localizations = try #require(entry["localizations"] as? [String: Any])
                let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
                let units = localizedUnits(in: chinese)
                #expect(!units.isEmpty, "No translated values: \(key)")
                for unit in units {
                    #expect(unit["state"] as? String == "translated", "Incomplete: \(key)")
                    #expect(!(unit["value"] as? String ?? "").isEmpty || key.isEmpty)
                }
            }
        }
    }

    @Test
    func countedToolResourcesUseCatalogPluralRules() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "Termind/Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])

        for key in [
            "%lld hosts", "%lld items", "%lld questions", "%lld results",
            "%lld tool calls", "%@ — %lld tools",
        ] {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let english = try #require(localizations["en"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            #expect(pluralForms(in: english).keys.sorted() == ["one", "other"])
            #expect(pluralForms(in: chinese).keys.sorted() == ["other"])
        }
    }

    @Test
    func coreChineseInterfaceTermsStayConsistent() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "Termind/Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let expected = [
            "App": "应用",
            "Version": "版本",
            "Welcome": "欢迎",
            "Snippets": "片段",
            "Ungrouped": "未分组",
            "Pin": "置顶",
            "Pinned": "置顶",
            "Unpin": "取消置顶",
            "Approve for me": "帮我批准",
            "Full access": "完全访问权限",
        ]

        for (key, translation) in expected {
            let entry = try #require(strings[key] as? [String: Any])
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let unit = try #require(chinese["stringUnit"] as? [String: Any])
            #expect(unit["value"] as? String == translation)
        }
    }

    private func localizedUnits(in value: [String: Any]) -> [[String: Any]] {
        if let unit = value["stringUnit"] as? [String: Any] { return [unit] }
        guard let variations = value["variations"] as? [String: Any] else { return [] }
        return variations.values.flatMap { variation -> [[String: Any]] in
            guard let forms = variation as? [String: Any] else { return [] }
            return forms.values.flatMap { form -> [[String: Any]] in
                guard let form = form as? [String: Any] else { return [] }
                return localizedUnits(in: form)
            }
        }
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

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
                let unit = try #require(chinese["stringUnit"] as? [String: Any])
                #expect(unit["state"] as? String == "translated", "Incomplete: \(key)")
                #expect(!(unit["value"] as? String ?? "").isEmpty || key.isEmpty)
            }
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

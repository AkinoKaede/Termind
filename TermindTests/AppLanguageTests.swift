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
    func editorLabelsAndForwardingMessagesHaveChineseTranslations() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appending(path: "Termind/Resources/Localizable.xcstrings")
        let root = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let strings = try #require(root["strings"] as? [String: Any])
        let labels = [
            "New Host", "Edit Host", "Import Key", "Generate Key", "Edit Key", "Export to Hosts",
            "New Group", "Edit Group", "New Snippet", "Edit Snippet", "New Package", "Edit Package",
            "New Identity", "Edit Identity", "Add Hosts", "Close",
            "New Port Forward", "Edit Port Forward", "Back", "Start", "Stop",
            "SOCKS Listen Port", "Listen Port", "Listen Address on This Mac",
            "Listen Address on SSH Host", "SOCKS Listen Address on This Mac",
            "Destination Host on This Mac", "Destination Host from SSH Host",
            "Unable to create an SSH forwarding session.", "SSH handshake failed",
            "Unable to start remote forwarding", "The forwarding SSH connection closed",
        ]
        let interpolations: [String: [String]] = [
            "%@ → listen %@ → This Mac → %@:%@": ["jump.example", "[::1]:8080", "db.internal", "5432"],
            "SOCKS5 %@ → %@ → Requested Target": ["[::1]:1080", "jump.example"],
            "SSH %@ → This Mac %@": ["[::1]:8080", "[2001:db8::1]:443"],
            "Unable to listen on %@: %@": ["[::1]:8080", "Address already in use"],
        ]

        for key in labels + interpolations.keys.sorted() {
            let entry = try #require(strings[key] as? [String: Any], "Missing editor or forwarding string: \(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            let chinese = try #require(localizations["zh-Hans"] as? [String: Any])
            let unit = try #require(chinese["stringUnit"] as? [String: Any])
            let translation = try #require(unit["value"] as? String)
            #expect(unit["state"] as? String == "translated")
            #expect(translation.range(of: "\\p{Han}", options: .regularExpression) != nil)

            if let arguments = interpolations[key] {
                let placeholders = translation.matches(of: /%(?:[1-9][0-9]*\$)?@/)
                #expect(placeholders.count == arguments.count, "Placeholder mismatch: \(key)")
                let rendered = String(format: translation, arguments: arguments)
                var remaining = rendered[...]
                for argument in arguments {
                    let range = try #require(remaining.range(of: argument), "Lost or reordered value: \(key)")
                    remaining = remaining[range.upperBound...]
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
            // `%lld results` is not here: `web_search`'s card moved to AgentKit
            // with the runtime, and so did the plural resource behind it.
            "%lld hosts", "%lld items", "%lld questions",
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

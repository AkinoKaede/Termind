// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@testable import TermindIOS

struct MobileLanguagePreferenceMigrationTests {
    @Test func removesLegacyInAppLanguagePreferences() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: SettingsKey.appLanguage)
        defaults.set([AppLanguage.simplifiedChinese.rawValue], forKey: "AppleLanguages")

        MobileLanguagePreferenceMigration.run(in: defaults)

        let domain = defaults.persistentDomain(forName: suiteName)
        #expect(domain?[SettingsKey.appLanguage] == nil)
        #expect(domain?["AppleLanguages"] == nil)
    }

    @Test func preservesSystemManagedPerAppLanguageWithoutLegacyMarker() throws {
        let (defaults, suiteName) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([AppLanguage.traditionalChinese.rawValue], forKey: "AppleLanguages")

        MobileLanguagePreferenceMigration.run(in: defaults)

        #expect(defaults.stringArray(forKey: "AppleLanguages") == [AppLanguage.traditionalChinese.rawValue])
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "MobileLanguagePreferenceMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

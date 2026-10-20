// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

nonisolated enum MobileLanguagePreferenceMigration {
    static func run(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.appLanguage) != nil else { return }
        defaults.removeObject(forKey: SettingsKey.appLanguage)
        defaults.removeObject(forKey: "AppleLanguages")
    }
}

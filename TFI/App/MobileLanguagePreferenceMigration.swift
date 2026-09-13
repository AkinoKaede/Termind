import Foundation
import TermindApplication

nonisolated enum MobileLanguagePreferenceMigration {
    static func run(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: SettingsKey.appLanguage) != nil else { return }
        defaults.removeObject(forKey: SettingsKey.appLanguage)
        defaults.removeObject(forKey: "AppleLanguages")
    }
}

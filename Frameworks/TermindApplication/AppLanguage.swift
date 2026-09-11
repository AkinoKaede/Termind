import Foundation

public nonisolated enum AppLocalization {
    public static func string(
        _ key: String.LocalizationValue, locale: Locale = .current
    ) -> String {
        String(
            localized: key,
            bundle: bundle(for: locale),
            locale: locale
        )
    }

    private static func bundle(for locale: Locale) -> Bundle {
        let localization: String? =
            switch locale.language.languageCode?.identifier {
            case "zh": "zh-Hans"
            case "en": "en"
            default: nil
            }
        guard let localization,
            let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return .main }
        return bundle
    }
}

public nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChineseChina = "zh-Hans-CN"

    public nonisolated var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .simplifiedChineseChina: "简体中文（中国）"
        }
    }

    public nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: SharedSettingsKey.appLanguage) else {
            return .system
        }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    /// Keeps the app's explicit choice separate from Apple's per-app language
    /// override. Removing `AppleLanguages` is what restores normal Bundle
    /// negotiation when the user chooses Follow System.
    public nonisolated static func store(
        _ language: AppLanguage, in defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: SharedSettingsKey.appLanguage)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChineseChina:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    public var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChineseChina: Locale(identifier: rawValue)
        }
    }
}

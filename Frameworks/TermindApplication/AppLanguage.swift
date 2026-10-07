import Foundation

public nonisolated enum AppLocalization {
    /// Resolves app copy, whose English default value is also its catalog key,
    /// using the effective language, including the desktop language override.
    public static func resolve(
        _ resource: LocalizedStringResource, locale: Locale = .current
    ) -> String {
        String(
            localized: resource.defaultValue, table: resource.table,
            bundle: bundle(for: locale), locale: locale
        )
    }

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
            case "zh": locale.language.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans"
            case "en": "en"
            case "ja": "ja"
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
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"

    public nonisolated var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        }
    }

    public func displayName(
        deviceRegion: String?, canDisplayTaiwanFlag: Bool
    ) -> String {
        guard self == .traditionalChinese else { return displayName }
        return deviceRegion == "TW" && canDisplayTaiwanFlag ? "正體中文" : "繁體中文"
    }

    public nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: SettingsKey.appLanguage) else {
            return .system
        }
        if let language = AppLanguage(rawValue: rawValue) {
            return language
        }
        let language = Locale(identifier: rawValue).language
        guard language.languageCode?.identifier == "zh",
            language.script?.identifier == "Hans"
        else { return .system }

        store(.simplifiedChinese, in: defaults)
        return .simplifiedChinese
    }

    /// Keeps the app's explicit choice separate from Apple's per-app language
    /// override. Removing `AppleLanguages` is what restores normal Bundle
    /// negotiation when the user chooses Follow System.
    public nonisolated static func store(
        _ language: AppLanguage, in defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: SettingsKey.appLanguage)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .japanese, .simplifiedChinese, .traditionalChinese:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    public var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .japanese, .simplifiedChinese, .traditionalChinese: Locale(identifier: rawValue)
        }
    }
}

import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Resolves an explicitly requested app language instead of relying on the
/// process-wide bundle negotiation. `String(localized:locale:)` uses `locale`
/// for formatting, but an already-running app (and the test host) can still
/// have a different preferred localization. Loading the matching lproj bundle
/// keeps locale-injectable presentation code deterministic.
nonisolated enum AppLocalization {
    static func string(
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

nonisolated enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChineseChina = "zh-Hans-CN"

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: "Follow System")
        case .english: "English"
        case .simplifiedChineseChina: "简体中文（中国）"
        }
    }

    nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: SettingsKey.appLanguage) else {
            return .system
        }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    /// Keeps the app's explicit choice separate from Apple's per-app language
    /// override. Removing `AppleLanguages` is what restores normal Bundle
    /// negotiation when the user chooses Follow System.
    nonisolated static func store(
        _ language: AppLanguage, in defaults: UserDefaults = .standard
    ) {
        defaults.set(language.rawValue, forKey: SettingsKey.appLanguage)
        switch language {
        case .system:
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChineseChina:
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .english: Locale(identifier: "en")
        case .simplifiedChineseChina: Locale(identifier: rawValue)
        }
    }
}

#if canImport(AppKit)
    @MainActor
    enum AppRelauncher {
        static func relaunch() {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            ) { _, error in
                guard error == nil else {
                    Task { @MainActor in NSSound.beep() }
                    return
                }
                Task { @MainActor in NSApp.terminate(nil) }
            }
        }
    }
#endif

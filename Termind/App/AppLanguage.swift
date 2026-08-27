import Foundation

#if canImport(AppKit)
    import AppKit
#endif

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

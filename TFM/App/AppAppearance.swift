import Foundation
import TermindPresentation

/// An app-wide override; `system` leaves macOS in control of the appearance.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: TermindCopy.Settings.followSystem)
        case .light: String(localized: TermindCopy.Settings.light)
        case .dark: String(localized: TermindCopy.Settings.dark)
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: DesktopSettingsKey.appAppearance)
            .flatMap(Self.init(rawValue:)) ?? .system
    }
}

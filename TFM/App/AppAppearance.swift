// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindPresentation

/// An app-wide override; `system` leaves macOS in control of the appearance.
nonisolated enum AppAppearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: String(localized: AppStrings.Settings.followSystem)
        case .light: String(localized: AppStrings.Settings.light)
        case .dark: String(localized: AppStrings.Settings.dark)
        }
    }

    static func stored(in defaults: UserDefaults = .standard) -> AppAppearance {
        defaults.string(forKey: DesktopSettingsKey.appAppearance)
            .flatMap(Self.init(rawValue:)) ?? .system
    }
}

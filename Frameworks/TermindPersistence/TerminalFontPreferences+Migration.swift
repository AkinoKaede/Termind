// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

extension TerminalFontPreferences {
    /// Read only the pre-upgrade local row, before Settings sync can replace it.
    /// Existing UserDefaults mirrors take precedence and are never overwritten.
    public nonisolated static func migrateLegacySettings(from localData: Data?, defaults: UserDefaults) throws {
        let needsSize = defaults.object(forKey: SettingsKey.terminalFontSize) == nil
        let needsFollowTheme = defaults.object(forKey: SettingsKey.terminalFontFollowTheme) == nil
        guard needsSize || needsFollowTheme else { return }
        struct LegacyTypography: Decodable {
            var fontSize: Double?
            var fontFollowTheme: Bool?
        }
        let legacy = try localData.map { try JSONDecoder().decode(LegacyTypography.self, from: $0) }
        let initial = Self()
        if needsSize { defaults.set(legacy?.fontSize ?? initial.size, forKey: SettingsKey.terminalFontSize) }
        if needsFollowTheme {
            defaults.set(
                legacy?.fontFollowTheme ?? initial.sizeFollowsTheme, forKey: SettingsKey.terminalFontFollowTheme)
        }
    }
}

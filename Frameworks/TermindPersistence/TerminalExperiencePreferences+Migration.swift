// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain

extension TerminalExperiencePreferences {
    /// Read only the pre-upgrade local row, before Settings sync can replace it.
    /// Existing UserDefaults mirrors, including explicit false values, take precedence.
    public nonisolated static func migrateLegacyMouseSettings(from localData: Data?, defaults: UserDefaults) throws {
        let needsCopy = defaults.object(forKey: SettingsKey.terminalCopyOnSelect) == nil
        let needsPaste = defaults.object(forKey: SettingsKey.terminalPasteOnRightClick) == nil
        guard needsCopy || needsPaste else { return }
        struct LegacyMouse: Decodable {
            var copyOnSelect: Bool?
            var pasteOnRightClick: Bool?
        }
        let legacy = try localData.map { try JSONDecoder().decode(LegacyMouse.self, from: $0) }
        let initial = Self()
        if needsCopy {
            defaults.set(legacy?.copyOnSelect ?? initial.copyOnSelect, forKey: SettingsKey.terminalCopyOnSelect)
        }
        if needsPaste {
            defaults.set(
                legacy?.pasteOnRightClick ?? initial.pasteOnRightClick, forKey: SettingsKey.terminalPasteOnRightClick)
        }
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@Observable
public final class TerminalExperienceSettingsModel {
    public private(set) var preferences: TerminalExperiencePreferences
    private let defaults: UserDefaults?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        var value = TerminalExperiencePreferences()
        value.bellSound = defaults?.object(forKey: SettingsKey.terminalBellSound) as? Bool ?? value.bellSound
        value.bellVibration =
            defaults?.object(forKey: SettingsKey.terminalBellVibration) as? Bool ?? value.bellVibration
        value.keepScreenAwake =
            defaults?.object(forKey: SettingsKey.terminalKeepScreenAwake) as? Bool ?? value.keepScreenAwake
        value.copyOnSelect = defaults?.object(forKey: SettingsKey.terminalCopyOnSelect) as? Bool ?? value.copyOnSelect
        value.pasteOnRightClick =
            defaults?.object(forKey: SettingsKey.terminalPasteOnRightClick) as? Bool ?? value.pasteOnRightClick
        preferences = value
    }

    public func set(_ value: Bool, for keyPath: WritableKeyPath<TerminalExperiencePreferences, Bool>) {
        guard preferences[keyPath: keyPath] != value else { return }
        preferences[keyPath: keyPath] = value
        defaults?.set(preferences.bellSound, forKey: SettingsKey.terminalBellSound)
        defaults?.set(preferences.bellVibration, forKey: SettingsKey.terminalBellVibration)
        defaults?.set(preferences.keepScreenAwake, forKey: SettingsKey.terminalKeepScreenAwake)
        defaults?.set(preferences.copyOnSelect, forKey: SettingsKey.terminalCopyOnSelect)
        defaults?.set(preferences.pasteOnRightClick, forKey: SettingsKey.terminalPasteOnRightClick)
    }
}

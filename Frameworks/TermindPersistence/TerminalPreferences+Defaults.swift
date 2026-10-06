import Foundation
import SwiftData
import TermindApplication
import TermindDomain

extension TerminalPreferences {
    public nonisolated init(defaults: UserDefaults) {
        self.init()
        darkTheme = defaults.string(forKey: SettingsKey.terminalThemeDark) ?? darkTheme
        lightTheme = defaults.string(forKey: SettingsKey.terminalThemeLight) ?? lightTheme
        darkCustomEnabled =
            defaults.object(forKey: SettingsKey.terminalCustomConfigurationDarkEnabled) as? Bool ?? false
        lightCustomEnabled =
            defaults.object(forKey: SettingsKey.terminalCustomConfigurationLightEnabled) as? Bool ?? false
        darkCustomConfiguration = defaults.string(forKey: SettingsKey.terminalCustomConfigurationDark) ?? ""
        lightCustomConfiguration = defaults.string(forKey: SettingsKey.terminalCustomConfigurationLight) ?? ""
        shellIntegration = defaults.object(forKey: SettingsKey.shellIntegration) as? Bool ?? shellIntegration
        copyOnSelect = defaults.bool(forKey: SettingsKey.terminalCopyOnSelect)
        pasteOnRightClick = defaults.bool(forKey: SettingsKey.terminalPasteOnRightClick)
    }

    public nonisolated func mirror(to defaults: UserDefaults) {
        defaults.set(darkTheme, forKey: SettingsKey.terminalThemeDark)
        defaults.set(lightTheme, forKey: SettingsKey.terminalThemeLight)
        defaults.set(darkCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationDarkEnabled)
        defaults.set(lightCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationLightEnabled)
        defaults.set(darkCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationDark)
        defaults.set(lightCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationLight)
        defaults.set(shellIntegration, forKey: SettingsKey.shellIntegration)
        defaults.set(copyOnSelect, forKey: SettingsKey.terminalCopyOnSelect)
        defaults.set(pasteOnRightClick, forKey: SettingsKey.terminalPasteOnRightClick)
    }
}

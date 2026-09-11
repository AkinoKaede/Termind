import Foundation
import SwiftData
import TermindDomain

extension TerminalPreferences {
    nonisolated init(defaults: UserDefaults) {
        self.init()
        fontSize = defaults.object(forKey: SettingsKey.terminalFontSize) as? Double ?? fontSize
        fontFollowTheme = defaults.object(forKey: SettingsKey.terminalFontFollowTheme) as? Bool ?? fontFollowTheme
        darkTheme = defaults.string(forKey: SettingsKey.terminalThemeDark) ?? darkTheme
        lightTheme = defaults.string(forKey: SettingsKey.terminalThemeLight) ?? lightTheme
        darkCustomEnabled =
            defaults.object(forKey: SettingsKey.terminalCustomConfigurationDarkEnabled) as? Bool ?? false
        lightCustomEnabled =
            defaults.object(forKey: SettingsKey.terminalCustomConfigurationLightEnabled) as? Bool ?? false
        darkCustomConfiguration = defaults.string(forKey: SettingsKey.terminalCustomConfigurationDark) ?? ""
        lightCustomConfiguration = defaults.string(forKey: SettingsKey.terminalCustomConfigurationLight) ?? ""
        shellIntegration = defaults.object(forKey: SettingsKey.shellIntegration) as? Bool ?? shellIntegration
        remoteWindowTitleInMenuBar =
            defaults.object(forKey: SettingsKey.remoteWindowTitleInMenuBar) as? Bool
            ?? remoteWindowTitleInMenuBar
    }

    nonisolated func mirror(to defaults: UserDefaults) {
        defaults.set(fontSize, forKey: SettingsKey.terminalFontSize)
        defaults.set(fontFollowTheme, forKey: SettingsKey.terminalFontFollowTheme)
        defaults.set(darkTheme, forKey: SettingsKey.terminalThemeDark)
        defaults.set(lightTheme, forKey: SettingsKey.terminalThemeLight)
        defaults.set(darkCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationDarkEnabled)
        defaults.set(lightCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationLightEnabled)
        defaults.set(darkCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationDark)
        defaults.set(lightCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationLight)
        defaults.set(shellIntegration, forKey: SettingsKey.shellIntegration)
        defaults.set(remoteWindowTitleInMenuBar, forKey: SettingsKey.remoteWindowTitleInMenuBar)
    }
}

import Foundation
import SwiftData
import TermindApplication
import TermindDomain

extension TerminalPreferences {
    public nonisolated init(defaults: UserDefaults) {
        self.init()
        fontSize = defaults.object(forKey: SharedSettingsKey.terminalFontSize) as? Double ?? fontSize
        fontFollowTheme = defaults.object(forKey: SharedSettingsKey.terminalFontFollowTheme) as? Bool ?? fontFollowTheme
        darkTheme = defaults.string(forKey: SharedSettingsKey.terminalThemeDark) ?? darkTheme
        lightTheme = defaults.string(forKey: SharedSettingsKey.terminalThemeLight) ?? lightTheme
        darkCustomEnabled =
            defaults.object(forKey: SharedSettingsKey.terminalCustomConfigurationDarkEnabled) as? Bool ?? false
        lightCustomEnabled =
            defaults.object(forKey: SharedSettingsKey.terminalCustomConfigurationLightEnabled) as? Bool ?? false
        darkCustomConfiguration = defaults.string(forKey: SharedSettingsKey.terminalCustomConfigurationDark) ?? ""
        lightCustomConfiguration = defaults.string(forKey: SharedSettingsKey.terminalCustomConfigurationLight) ?? ""
        shellIntegration = defaults.object(forKey: SharedSettingsKey.shellIntegration) as? Bool ?? shellIntegration
        remoteWindowTitleInMenuBar =
            defaults.object(forKey: SharedSettingsKey.remoteWindowTitleInMenuBar) as? Bool
            ?? remoteWindowTitleInMenuBar
    }

    public nonisolated func mirror(to defaults: UserDefaults) {
        defaults.set(fontSize, forKey: SharedSettingsKey.terminalFontSize)
        defaults.set(fontFollowTheme, forKey: SharedSettingsKey.terminalFontFollowTheme)
        defaults.set(darkTheme, forKey: SharedSettingsKey.terminalThemeDark)
        defaults.set(lightTheme, forKey: SharedSettingsKey.terminalThemeLight)
        defaults.set(darkCustomEnabled, forKey: SharedSettingsKey.terminalCustomConfigurationDarkEnabled)
        defaults.set(lightCustomEnabled, forKey: SharedSettingsKey.terminalCustomConfigurationLightEnabled)
        defaults.set(darkCustomConfiguration, forKey: SharedSettingsKey.terminalCustomConfigurationDark)
        defaults.set(lightCustomConfiguration, forKey: SharedSettingsKey.terminalCustomConfigurationLight)
        defaults.set(shellIntegration, forKey: SharedSettingsKey.shellIntegration)
        defaults.set(remoteWindowTitleInMenuBar, forKey: SharedSettingsKey.remoteWindowTitleInMenuBar)
    }
}

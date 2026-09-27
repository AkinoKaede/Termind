import Foundation
import SwiftData
import TermindApplication
import TermindDomain

extension TerminalPreferences {
    public nonisolated init(defaults: UserDefaults) {
        self.init()
        if let data = defaults.data(forKey: SettingsKey.commandNotifications),
            let value = try? JSONDecoder().decode(CommandNotificationPreferences.self, from: data)
        {
            commandNotifications = value
        }
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
        copyOnSelect = defaults.bool(forKey: SettingsKey.terminalCopyOnSelect)
        pasteOnRightClick = defaults.bool(forKey: SettingsKey.terminalPasteOnRightClick)
    }

    public nonisolated func mirror(to defaults: UserDefaults) {
        defaults.set(try? JSONEncoder().encode(commandNotifications), forKey: SettingsKey.commandNotifications)
        defaults.set(darkTheme, forKey: SettingsKey.terminalThemeDark)
        defaults.set(lightTheme, forKey: SettingsKey.terminalThemeLight)
        defaults.set(darkCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationDarkEnabled)
        defaults.set(lightCustomEnabled, forKey: SettingsKey.terminalCustomConfigurationLightEnabled)
        defaults.set(darkCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationDark)
        defaults.set(lightCustomConfiguration, forKey: SettingsKey.terminalCustomConfigurationLight)
        defaults.set(shellIntegration, forKey: SettingsKey.shellIntegration)
        defaults.set(remoteWindowTitleInMenuBar, forKey: SettingsKey.remoteWindowTitleInMenuBar)
        defaults.set(copyOnSelect, forKey: SettingsKey.terminalCopyOnSelect)
        defaults.set(pasteOnRightClick, forKey: SettingsKey.terminalPasteOnRightClick)
    }
}

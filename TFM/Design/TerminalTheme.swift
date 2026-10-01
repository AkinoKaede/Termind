import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct ResolvedTerminalAppearance: Equatable {
    var preferences: TerminalPreferences
    var font: TerminalFontPreferences
}

/// The live terminal appearance selected in Settings.
///
/// Only settings changes reconfigure the surface. Its live background is observed separately.
@propertyWrapper
struct TerminalAppearanceSettings: DynamicProperty {
    @TerminalFontSettings private var font
    @AppStorage(SettingsKey.terminalThemeDark) private var darkTheme =
        SettingsKey.defaultTerminalThemeDark
    @AppStorage(SettingsKey.terminalThemeLight) private var lightTheme =
        SettingsKey.defaultTerminalThemeLight
    @AppStorage(SettingsKey.terminalCustomConfigurationDarkEnabled)
    private var darkCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationLightEnabled)
    private var lightCustomEnabled = false
    @AppStorage(SettingsKey.terminalCustomConfigurationDark)
    private var darkCustomConfiguration = ""
    @AppStorage(SettingsKey.terminalCustomConfigurationLight)
    private var lightCustomConfiguration = ""

    var wrappedValue: ResolvedTerminalAppearance {
        let preferences = TerminalPreferences(
            darkTheme: darkTheme,
            lightTheme: lightTheme,
            darkCustomEnabled: darkCustomEnabled,
            lightCustomEnabled: lightCustomEnabled,
            darkCustomConfiguration: darkCustomConfiguration,
            lightCustomConfiguration: lightCustomConfiguration
        )
        return ResolvedTerminalAppearance(
            preferences: preferences,
            font: font.resolvingFamily(in: TerminalFontCatalog.shared.families)
        )
    }
}

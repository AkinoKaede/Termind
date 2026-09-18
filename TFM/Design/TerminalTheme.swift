import Foundation
import SwiftUI
import TermindApplication
/// Fallback colors for the SwiftUI chrome around the terminal.
///
/// These palettes drive both the terminal surface and its SwiftUI chrome, which
/// keeps banners and empty areas visually continuous around the grid.
import TermindDomain
import TermindPresentation

struct ResolvedTerminalAppearance: Equatable {
    var preferences: TerminalPreferences
    var font: TerminalFontPreferences
    var background: Color
}

/// The live terminal appearance selected in Settings.
///
/// Terminal-adjacent SwiftUI chrome uses this alongside the Ghostty surface so
/// both react to the same theme, custom configuration, and system appearance.
@propertyWrapper
struct TerminalAppearanceSettings: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
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
        let isDark = colorScheme == .dark
        return ResolvedTerminalAppearance(
            preferences: preferences,
            font: font.resolvingFamily(in: TerminalFontCatalog.shared.families),
            background: TermindTerminalThemeCatalog.background(
                themeName: isDark ? darkTheme : lightTheme,
                customEnabled: isDark ? darkCustomEnabled : lightCustomEnabled,
                customText: isDark ? darkCustomConfiguration : lightCustomConfiguration,
                isDark: isDark
            ).color
        )
    }
}

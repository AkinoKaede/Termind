import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import TermindApplication
/// Fallback colors for the SwiftUI chrome around the terminal.
///
/// These palettes drive both the terminal surface and its SwiftUI chrome, which
/// keeps banners and empty areas visually continuous around the grid.
import TermindDomain

nonisolated extension TermindTerminalPalette.RGB {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}
nonisolated extension TermindTerminalPalette {
    /// The same palette expressed in the format consumed by libghostty. The
    /// SwiftUI chrome and the terminal grid therefore share one definition
    /// instead of merely using similarly named colors.
    var ghosttyDefinition: GhosttyThemeDefinition {
        GhosttyThemeDefinition(
            name: name,
            background: background.hex,
            foreground: foreground.hex,
            cursorColor: cursor.hex,
            cursorText: background.hex,
            selectionBackground: selection.hex,
            selectionForeground: foreground.hex,
            palette: Dictionary(uniqueKeysWithValues: ansi.enumerated().map { ($0, $1.hex) })
        )
    }
}

nonisolated extension TerminalCustomConfiguration {
    func applying(to base: GhosttyTerminal.TerminalConfiguration)
        -> GhosttyTerminal.TerminalConfiguration
    {
        GhosttyTerminal.TerminalConfiguration(startingFrom: base) { builder in
            for entry in entries {
                builder.withCustom(entry.key, entry.value)
            }
        }
    }

}

nonisolated struct TerminalAppearancePreferences: Hashable, Sendable {
    var lightThemeName: String
    var darkThemeName: String
    var lightCustomEnabled: Bool
    var darkCustomEnabled: Bool
    var lightCustomConfiguration: String
    var darkCustomConfiguration: String
    var fontFollowTheme: Bool
    var fontSize: Double
}

@MainActor
extension TerminalViewState {
    func applyAppearance(_ preferences: TerminalAppearancePreferences) {
        let light = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.lightThemeName,
            customEnabled: preferences.lightCustomEnabled,
            customText: preferences.lightCustomConfiguration,
            isDark: false
        )
        let dark = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: preferences.darkThemeName,
            customEnabled: preferences.darkCustomEnabled,
            customText: preferences.darkCustomConfiguration,
            isDark: true
        )
        setTheme(GhosttyTerminal.TerminalTheme(light: light, dark: dark))
        setTerminalConfiguration(
            GhosttyTerminal.TerminalConfiguration { builder in
                if !preferences.fontFollowTheme {
                    builder.withFontSize(Float(preferences.fontSize))
                }
                builder.withWindowPaddingX(Int(Metrics.Space.m))
                builder.withWindowPaddingY(Int(Metrics.Space.m))
            }
        )
    }
}

struct ResolvedTerminalAppearance {
    var preferences: TerminalAppearancePreferences
    var background: Color
}

/// The live terminal appearance selected in Settings.
///
/// Terminal-adjacent SwiftUI chrome uses this alongside the Ghostty surface so
/// both react to the same theme, custom configuration, and system appearance.
@propertyWrapper
struct TerminalAppearanceSettings: DynamicProperty {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = 12.0
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
    @AppStorage(SettingsKey.terminalFontFollowTheme) private var fontFollowTheme = true

    var wrappedValue: ResolvedTerminalAppearance {
        let preferences = TerminalAppearancePreferences(
            lightThemeName: lightTheme,
            darkThemeName: darkTheme,
            lightCustomEnabled: lightCustomEnabled,
            darkCustomEnabled: darkCustomEnabled,
            lightCustomConfiguration: lightCustomConfiguration,
            darkCustomConfiguration: darkCustomConfiguration,
            fontFollowTheme: fontFollowTheme,
            fontSize: fontSize
        )
        let isDark = colorScheme == .dark
        return ResolvedTerminalAppearance(
            preferences: preferences,
            background: TermindTerminalThemeCatalog.background(
                themeName: isDark ? darkTheme : lightTheme,
                customEnabled: isDark ? darkCustomEnabled : lightCustomEnabled,
                customText: isDark ? darkCustomConfiguration : lightCustomConfiguration,
                isDark: isDark
            ).color
        )
    }
}

/// One lookup surface for Termind's palettes and the themes bundled with Ghostty.
/// Custom palettes come first and replace a bundled theme with the same name,
/// should one ever be added upstream.
nonisolated enum TermindTerminalThemeCatalog {
    static let allThemes: [GhosttyThemeDefinition] = {
        let termindThemes = TermindTerminalPalette.all.map(\.ghosttyDefinition)
        let termindNames = Set(termindThemes.map(\.name))
        return termindThemes + GhosttyThemeCatalog.allThemes.filter { !termindNames.contains($0.name) }
    }()

    static func theme(named name: String) -> GhosttyThemeDefinition? {
        allThemes.first { $0.name == name }
    }

    static func darkTheme(named name: String) -> GhosttyThemeDefinition? {
        theme(named: name).flatMap { $0.isDark ? $0 : nil }
    }

    static func lightTheme(named name: String) -> GhosttyThemeDefinition? {
        theme(named: name).flatMap { $0.isDark ? nil : $0 }
    }

    static let defaultDark = TermindTerminalPalette.termindDark.ghosttyDefinition
    static let defaultLight = TermindTerminalPalette.termindLight.ghosttyDefinition

    static func terminalConfiguration(
        themeName: String,
        customEnabled: Bool,
        customText: String,
        isDark: Bool
    ) -> GhosttyTerminal.TerminalConfiguration {
        let fallback = isDark ? defaultDark : defaultLight
        let selected = theme(named: themeName).flatMap { $0.isDark == isDark ? $0 : nil } ?? fallback
        let base = selected.toTerminalConfiguration()
        guard customEnabled else { return base }
        return TerminalCustomConfiguration(customText).applying(to: base)
    }

    static func background(
        themeName: String,
        customEnabled: Bool,
        customText: String,
        isDark: Bool
    ) -> TermindTerminalPalette.RGB {
        let fallback = isDark ? defaultDark : defaultLight
        let selected = theme(named: themeName).flatMap { $0.isDark == isDark ? $0 : nil } ?? fallback
        if customEnabled,
            let value = TerminalCustomConfiguration(customText).lastValue(for: "background"),
            let customBackground = TermindTerminalPalette.RGB(hex: value)
        {
            return customBackground
        }
        return TermindTerminalPalette.RGB(hex: selected.background)
            ?? (isDark ? TermindTerminalPalette.termindDark.background : TermindTerminalPalette.termindLight.background)
    }
}

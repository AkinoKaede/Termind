import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import TermindDomain

nonisolated extension TermindTerminalPalette.RGB {
    public var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
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
            // Command alerts are owned by the app's shared settings and dispatcher.
            for entry in entries where entry.key != "notify-on-command-finish" {
                builder.withCustom(entry.key, entry.value)
            }
        }
    }

}

public nonisolated enum TermindTerminalThemeCatalog {
    public static let allThemes: [GhosttyThemeDefinition] = {
        let termindThemes = TermindTerminalPalette.all.map(\.ghosttyDefinition)
        let termindNames = Set(termindThemes.map(\.name))
        return termindThemes + GhosttyThemeCatalog.allThemes.filter { !termindNames.contains($0.name) }
    }()

    public static func theme(named name: String) -> GhosttyThemeDefinition? {
        allThemes.first { $0.name == name }
    }

    public static let defaultDark = TermindTerminalPalette.termindDark.ghosttyDefinition
    public static let defaultLight = TermindTerminalPalette.termindLight.ghosttyDefinition
    public static let darkThemes = allThemes.filter(\.isDark).sorted { $0.name < $1.name }
    public static let lightThemes = allThemes.filter { !$0.isDark }.sorted { $0.name < $1.name }

    public static func themes(isDark: Bool) -> [GhosttyThemeDefinition] {
        isDark ? darkThemes : lightThemes
    }

    public static func fallbackTheme(isDark: Bool) -> GhosttyThemeDefinition {
        isDark ? defaultDark : defaultLight
    }

    public static func resolvedTheme(named name: String, isDark: Bool) -> GhosttyThemeDefinition {
        theme(named: name).flatMap { $0.isDark == isDark ? $0 : nil } ?? fallbackTheme(isDark: isDark)
    }

    public static func terminalConfiguration(
        themeName: String,
        customEnabled: Bool,
        customText: String,
        isDark: Bool,
        font: TerminalFontPreferences = .init()
    ) -> GhosttyTerminal.TerminalConfiguration {
        let selected = resolvedTheme(named: themeName, isDark: isDark)
        let base = selected.toTerminalConfiguration()
        let themed = customEnabled ? TerminalCustomConfiguration(customText).applying(to: base) : base
        // Ghostty renders theme commands after session overrides. Typography must
        // come last here, and font-family is a list that needs an explicit reset.
        return GhosttyTerminal.TerminalConfiguration(startingFrom: themed) { builder in
            if !font.family.isEmpty {
                builder.withFontFamily("")
                builder.withFontFamily(font.family)
            }
            if !font.sizeFollowsTheme { builder.withFontSize(Float(font.size)) }
        }
    }

}

@MainActor
extension TerminalViewState {
    public func applyPreferences(
        _ value: TerminalPreferences, font: TerminalFontPreferences = .init(),
        library: TerminalThemeLibrary = .init()
    ) {
        let lightOptions = TerminalThemeOptions(preferences: value, isDark: false, library: library)
        let darkOptions = TerminalThemeOptions(preferences: value, isDark: true, library: library)
        let light = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: lightOptions.baseTheme.name,
            customEnabled: lightOptions.isCustom, customText: lightOptions.customText,
            isDark: lightOptions.baseTheme.isDark,
            font: font)
        let dark = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: darkOptions.baseTheme.name,
            customEnabled: darkOptions.isCustom, customText: darkOptions.customText,
            isDark: darkOptions.baseTheme.isDark,
            font: font)
        setTheme(GhosttyTerminal.TerminalTheme(light: light, dark: dark))
        setTerminalConfiguration(
            GhosttyTerminal.TerminalConfiguration { builder in
                builder.withCustom("notify-on-command-finish", "never")
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
            })
    }
}

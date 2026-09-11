import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI
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

@MainActor
extension TerminalViewState {
    func applyPreferences(_ value: TerminalPreferences) {
        let light = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: value.lightTheme,
            customEnabled: value.lightCustomEnabled, customText: value.lightCustomConfiguration, isDark: false)
        let dark = TermindTerminalThemeCatalog.terminalConfiguration(
            themeName: value.darkTheme,
            customEnabled: value.darkCustomEnabled, customText: value.darkCustomConfiguration, isDark: true)
        setTheme(GhosttyTerminal.TerminalTheme(light: light, dark: dark))
        setTerminalConfiguration(
            GhosttyTerminal.TerminalConfiguration { builder in
                if !value.fontFollowTheme { builder.withFontSize(Float(value.fontSize)) }
                builder.withWindowPaddingX(8)
                builder.withWindowPaddingY(8)
            })
    }
}

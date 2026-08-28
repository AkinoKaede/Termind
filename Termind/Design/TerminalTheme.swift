import Foundation
import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// Fallback colors for the SwiftUI chrome around the terminal.
///
/// These palettes drive both the terminal surface and its SwiftUI chrome, which
/// keeps banners and empty areas visually continuous around the grid.
nonisolated struct TerminalTheme: Identifiable, Hashable, Sendable {
    nonisolated struct RGB: Hashable, Sendable {
        var r: Double, g: Double, b: Double

        init(_ hex: UInt32) {
            r = Double((hex >> 16) & 0xFF) / 255
            g = Double((hex >> 8) & 0xFF) / 255
            b = Double(hex & 0xFF) / 255
        }

        init?(hex value: String) {
            var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.hasPrefix("#") { normalized.removeFirst() }
            guard normalized.count == 6, let hex = UInt32(normalized, radix: 16) else {
                return nil
            }
            self.init(hex)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

        var hex: String {
            String(
                format: "%02X%02X%02X",
                Int((r * 255).rounded()),
                Int((g * 255).rounded()),
                Int((b * 255).rounded())
            )
        }
    }

    var id: String { name }
    var name: String
    var isDark: Bool

    var background: RGB
    var foreground: RGB
    var cursor: RGB
    var selection: RGB

    /// ANSI 0-7 followed by their bright variants 8-15.
    var ansi: [RGB]

    static let termindDark = TerminalTheme(
        name: SettingsKey.defaultTerminalThemeDark,
        isDark: true,
        background: RGB(0x11141A),
        foreground: RGB(0xD3D8E0),
        cursor: RGB(0x4B8BF5),
        selection: RGB(0x2A3550),
        ansi: [
            RGB(0x2A2F3A), RGB(0xE05561), RGB(0x62C073), RGB(0xD5A24C),
            RGB(0x4B8BF5), RGB(0xB07CD8), RGB(0x3FB5B5), RGB(0xABB2BF),
            RGB(0x515A6C), RGB(0xFF6E76), RGB(0x7BD98C), RGB(0xEFBD5D),
            RGB(0x6BA5FF), RGB(0xC996E8), RGB(0x56CFCF), RGB(0xE6E9EF),
        ]
    )

    static let termindLight = TerminalTheme(
        name: SettingsKey.defaultTerminalThemeLight,
        isDark: false,
        background: RGB(0xFBFBFD),
        foreground: RGB(0x2B303B),
        cursor: RGB(0x2C6BD8),
        selection: RGB(0xCFDDF7),
        ansi: [
            RGB(0x3B4048), RGB(0xC4404B), RGB(0x3F8F4E), RGB(0x9C7415),
            RGB(0x2C6BD8), RGB(0x8A4FB8), RGB(0x24888A), RGB(0x6C737F),
            RGB(0x545C69), RGB(0xE05561), RGB(0x53A863), RGB(0xBB8D22),
            RGB(0x3F82EA), RGB(0xA463D0), RGB(0x2FA5A7), RGB(0x2B303B),
        ]
    )

    static let all: [TerminalTheme] = [.termindDark, .termindLight]

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

/// A small, deliberately permissive parser for Ghostty's line-oriented config.
/// Ghostty remains the authority on supported keys and values; Termind only
/// removes comments and malformed lines before forwarding entries in order.
nonisolated struct GhosttyCustomConfiguration: Hashable, Sendable {
    nonisolated struct Entry: Hashable, Sendable {
        var key: String
        var value: String
    }

    var entries: [Entry]

    init(_ text: String) {
        entries = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap {
            rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=")
            else { return nil }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { return nil }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return Entry(key: key, value: value)
        }
    }

    func applying(to base: GhosttyTerminal.TerminalConfiguration)
        -> GhosttyTerminal.TerminalConfiguration
    {
        GhosttyTerminal.TerminalConfiguration(startingFrom: base) { builder in
            for entry in entries {
                builder.withCustom(entry.key, entry.value)
            }
        }
    }

    func lastValue(for key: String) -> String? {
        entries.last { $0.key == key }?.value
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
        let termindThemes = TerminalTheme.all.map(\.ghosttyDefinition)
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

    static let defaultDark = TerminalTheme.termindDark.ghosttyDefinition
    static let defaultLight = TerminalTheme.termindLight.ghosttyDefinition

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
        return GhosttyCustomConfiguration(customText).applying(to: base)
    }

    static func background(
        themeName: String,
        customEnabled: Bool,
        customText: String,
        isDark: Bool
    ) -> TerminalTheme.RGB {
        let fallback = isDark ? defaultDark : defaultLight
        let selected = theme(named: themeName).flatMap { $0.isDark == isDark ? $0 : nil } ?? fallback
        if customEnabled,
            let value = GhosttyCustomConfiguration(customText).lastValue(for: "background"),
            let customBackground = TerminalTheme.RGB(hex: value)
        {
            return customBackground
        }
        return TerminalTheme.RGB(hex: selected.background)
            ?? (isDark ? TerminalTheme.termindDark.background : TerminalTheme.termindLight.background)
    }
}

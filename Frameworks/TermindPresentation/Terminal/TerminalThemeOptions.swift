import GhosttyTheme
import SwiftUI
import TermindDomain

/// Read-only presentation of the existing light/dark preferences. Opening a browser never repairs storage.
public struct TerminalThemeOptions {
    public let preferences: TerminalPreferences
    public let isDark: Bool
    public let library: TerminalThemeLibrary

    public init(preferences: TerminalPreferences, isDark: Bool, library: TerminalThemeLibrary = .init()) {
        self.preferences = preferences
        self.isDark = isDark
        self.library = library
    }

    public var selectedCustomTheme: TerminalCustomTheme? { library.selectedTheme(isDark: isDark) }
    private var selection: TerminalThemeSelection? { library.selection(isDark: isDark) }
    public var name: String {
        selectedCustomTheme?.baseThemeName ?? selection?.builtInThemeName
            ?? (isDark ? preferences.darkTheme : preferences.lightTheme)
    }
    public var isCustom: Bool {
        if selection != nil { return selectedCustomTheme != nil }
        return isDark ? preferences.darkCustomEnabled : preferences.lightCustomEnabled
    }
    public var customText: String {
        if selection != nil { return selectedCustomTheme?.configuration ?? "" }
        return isDark ? preferences.darkCustomConfiguration : preferences.lightCustomConfiguration
    }
    public var title: LocalizedStringResource {
        isDark ? AppStrings.Settings.darkTheme : AppStrings.Settings.lightTheme
    }
    public var summary: Text {
        if let theme = selectedCustomTheme {
            Text(verbatim: theme.name)
        } else if isCustom {
            Text(AppStrings.Settings.customTheme)
        } else if name.isEmpty {
            Text(AppStrings.Settings.noThemeSelected)
        } else {
            Text(verbatim: name)
        }
    }
    public var isAvailable: Bool {
        if let theme = selectedCustomTheme {
            return TermindTerminalThemeCatalog.theme(named: theme.baseThemeName) != nil
        }
        if selection?.customThemeID != nil { return false }
        return TermindTerminalThemeCatalog.theme(named: name)?.isDark == isDark
    }
    public var baseTheme: GhosttyThemeDefinition {
        selectedCustomTheme?.baseTheme ?? TermindTerminalThemeCatalog.resolvedTheme(named: name, isDark: isDark)
    }
    public func themes(matching query: String) -> [GhosttyThemeDefinition] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TermindTerminalThemeCatalog.themes(isDark: isDark).filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
    }
    public func isSelected(_ name: String) -> Bool { !isCustom && self.name == name }

    public func customThemes(matching query: String) -> [TerminalCustomTheme] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.themes.filter {
            $0.appearance.includes(isDark: isDark) && (query.isEmpty || $0.name.localizedStandardContains(query))
        }.sorted {
            $0.name == $1.name
                ? $0.id.uuidString < $1.id.uuidString : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

extension TerminalCustomTheme {
    public var baseTheme: GhosttyThemeDefinition {
        TermindTerminalThemeCatalog.theme(named: baseThemeName)
            ?? TermindTerminalThemeCatalog.fallbackTheme(isDark: appearance != .light)
    }
}

extension TerminalThemeAppearance {
    public var title: LocalizedStringResource {
        switch self {
        case .light: AppStrings.Settings.themeLight
        case .dark: AppStrings.Settings.themeDark
        case .both: AppStrings.Settings.themeBoth
        }
    }
}

public struct TerminalThemeAvailabilityNotice: View {
    private let options: TerminalThemeOptions

    public init(options: TerminalThemeOptions) { self.options = options }

    public var body: some View {
        if !options.isAvailable {
            Text(AppStrings.Settings.unavailableThemeFallback(options.baseTheme.name))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

import GhosttyTheme
import SwiftUI
import TermindDomain

/// Read-only presentation of the existing light/dark preferences. Opening a browser never repairs storage.
public struct TerminalThemeOptions {
    public let preferences: TerminalPreferences
    public let isDark: Bool

    public init(preferences: TerminalPreferences, isDark: Bool) {
        self.preferences = preferences
        self.isDark = isDark
    }

    public var name: String { isDark ? preferences.darkTheme : preferences.lightTheme }
    public var isCustom: Bool { isDark ? preferences.darkCustomEnabled : preferences.lightCustomEnabled }
    public var customText: String {
        isDark ? preferences.darkCustomConfiguration : preferences.lightCustomConfiguration
    }
    public var title: LocalizedStringResource {
        isDark ? AppStrings.Settings.darkTheme : AppStrings.Settings.lightTheme
    }
    public var summary: Text {
        if isCustom {
            Text(AppStrings.Settings.customTheme)
        } else if name.isEmpty {
            Text(AppStrings.Settings.noThemeSelected)
        } else {
            Text(verbatim: name)
        }
    }
    public var isAvailable: Bool { TermindTerminalThemeCatalog.theme(named: name)?.isDark == isDark }
    public var baseTheme: GhosttyThemeDefinition {
        TermindTerminalThemeCatalog.resolvedTheme(named: name, isDark: isDark)
    }
    public func themes(matching query: String) -> [GhosttyThemeDefinition] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return TermindTerminalThemeCatalog.themes(isDark: isDark).filter {
            query.isEmpty || $0.name.localizedStandardContains(query)
        }
    }
    public func isSelected(_ name: String) -> Bool { !isCustom && self.name == name }
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

import SwiftUI
import TermindDomain

public struct TerminalCustomThemeSummary: View {
    private let theme: TerminalCustomTheme
    private let library: TerminalThemeLibrary

    public init(theme: TerminalCustomTheme, library: TerminalThemeLibrary) {
        self.theme = theme
        self.library = library
    }

    public var body: some View {
        HStack(spacing: 12) {
            TerminalThemeThumbnail(theme: theme.baseTheme, customText: theme.configuration)
                .frame(width: 96)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: theme.name).font(.headline)
                Text(theme.appearance.title).font(.caption).foregroundStyle(.secondary)
                ForEach([false, true], id: \.self) { isDark in
                    if library.selectedTheme(isDark: isDark)?.id == theme.id {
                        Label(
                            (isDark ? AppStrings.Settings.darkTheme : AppStrings.Settings.lightTheme).swiftUIKey,
                            systemImage: "checkmark"
                        )
                        .font(.caption).foregroundStyle(.tint)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension TerminalThemeLibrary {
    public func themes(matching query: String) -> [TerminalCustomTheme] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return themes.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted {
            if $0.name == $1.name { return $0.id.uuidString < $1.id.uuidString }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

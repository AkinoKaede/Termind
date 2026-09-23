import GhosttyTheme
import SwiftUI

public struct TerminalThemePicker: View {
    @Binding private var selection: String
    private let isDark: Bool

    public init(selection: Binding<String>, isDark: Bool) {
        _selection = selection
        self.isDark = isDark
    }

    private var themes: [GhosttyThemeDefinition] {
        TermindTerminalThemeCatalog.themes(isDark: isDark)
    }

    private var selectedThemeIsAvailable: Bool {
        TermindTerminalThemeCatalog.theme(named: selection)?.isDark == isDark
    }

    private var fallbackName: String {
        TermindTerminalThemeCatalog.fallbackTheme(isDark: isDark).name
    }

    public var body: some View {
        Picker(TermindCopy.Settings.theme.swiftUIKey, selection: $selection) {
            if !selectedThemeIsAvailable {
                if selection.isEmpty {
                    Text("No Theme Selected").tag(selection)
                } else {
                    Text(verbatim: selection).tag(selection)
                }
            }
            ForEach(themes, id: \.name) { theme in
                Text(verbatim: theme.name).tag(theme.name)
            }
        }
        if !selectedThemeIsAvailable {
            Text("This theme is unavailable for this appearance. Using “\(Text(verbatim: fallbackName))” instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

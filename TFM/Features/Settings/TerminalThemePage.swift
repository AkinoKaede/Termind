import GhosttyTheme
import SwiftUI
import TermindPresentation

struct TerminalThemePage: View {
    let scheme: TerminalCustomConfigurationScheme
    let editConfiguration: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window

    private var query: String { window.terminalThemeQueries[scheme, default: ""] }
    @State private var hoveredTheme: String?

    private var options: TerminalThemeOptions {
        .init(preferences: app.terminalSettings.preferences, isDark: scheme == .dark)
    }

    var body: some View {
        CardPage {
            if let error = app.terminalSettings.storageError {
                Text(error).foregroundStyle(.red)
            }
            TerminalThemeAvailabilityNotice(options: options)
            CardGrid {
                ForEach(options.themes(matching: query)) { theme in
                    tile(theme: theme, custom: false)
                }

                tile(theme: options.baseTheme, custom: true)
            }
            if options.themes(matching: query).isEmpty {
                Text(AppStrings.Settings.noMatchingThemes).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(theme: GhosttyThemeDefinition, custom: Bool) -> some View {
        let hoverID = custom ? "__custom__" : theme.name
        let selected = custom ? options.isCustom : options.isSelected(theme.name)
        let select: () -> Void = {
            let saved =
                custom
                ? app.terminalSettings.selectCustomTheme(isDark: scheme == .dark)
                : app.terminalSettings.selectTheme(named: theme.name, isDark: scheme == .dark)
            if saved { window.navigateBackInSettings() }
        }
        return CardTile(
            isSelected: selected,
            activate: select, activatesOnReturn: true, activatesOnSingleClick: true
        ) {
            HStack(spacing: Metrics.Space.m) {
                TerminalThemeThumbnail(
                    theme: theme, customText: custom ? options.customText : "", showsPalette: hoveredTheme == hoverID
                )
                .frame(width: 108)
                if custom {
                    Text(AppStrings.Settings.customTheme).font(.headline)
                } else {
                    Text(verbatim: theme.name).font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, custom ? Metrics.Space.xl : 0)
        }
        .onHover { hovering in
            if hovering { hoveredTheme = hoverID } else if hoveredTheme == hoverID { hoveredTheme = nil }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityAction { select() }
        .onKeyPress(.space) {
            select()
            return .handled
        }
        .contextMenu {
            if custom {
                Button(
                    AppStrings.Common.edit.swiftUIKey, systemImage: "pencil",
                    action: editConfiguration)
            }
        }
        .overlay(alignment: .topTrailing) {
            if custom {
                Button(action: editConfiguration) {
                    Label(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(Text(AppStrings.Common.edit))
                .padding(Metrics.Space.m)
            }
        }
    }
}

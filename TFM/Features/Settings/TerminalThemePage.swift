// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTheme
import SwiftUI
import TermindDomain
import TermindPresentation

struct TerminalThemePage: View {
    let scheme: TerminalCustomConfigurationScheme
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @State private var hoveredTheme: String?

    private var query: String { window.terminalThemeQueries[scheme, default: ""] }
    private var options: TerminalThemeOptions {
        .init(
            preferences: app.terminalSettings.preferences, isDark: scheme == .dark,
            library: app.terminalSettings.themeLibrary)
    }

    var body: some View {
        CardPage {
            if let error = app.terminalSettings.storageError { Text(error).foregroundStyle(.red) }
            TerminalThemeAvailabilityNotice(options: options)
            if !options.customThemes(matching: query).isEmpty {
                Text(AppStrings.Settings.customThemes).font(.headline)
                CardGrid {
                    ForEach(options.customThemes(matching: query)) { theme in
                        tile(theme: theme.baseTheme, custom: theme)
                    }
                }
            }
            if !options.themes(matching: query).isEmpty {
                Text(AppStrings.Settings.builtInThemes).font(.headline)
                CardGrid {
                    ForEach(options.themes(matching: query)) { theme in tile(theme: theme) }
                }
            } else if options.customThemes(matching: query).isEmpty {
                Text(AppStrings.Settings.noMatchingThemes).foregroundStyle(.secondary)
            }
        }
    }

    private func tile(theme: GhosttyThemeDefinition, custom: TerminalCustomTheme? = nil) -> some View {
        let hoverID = custom?.id.uuidString ?? theme.name
        let selected = custom.map { options.selectedCustomTheme?.id == $0.id } ?? options.isSelected(theme.name)
        let select: () -> Void = {
            let saved: Bool
            if let custom {
                saved = app.terminalSettings.selectCustomTheme(id: custom.id, isDark: scheme == .dark)
            } else {
                saved = app.terminalSettings.selectTheme(named: theme.name, isDark: scheme == .dark)
            }
            if saved { window.navigateBackInSettings() }
        }
        return CardTile(isSelected: selected, activate: select, activatesOnReturn: true, activatesOnSingleClick: true) {
            HStack(spacing: Metrics.Space.m) {
                TerminalThemeThumbnail(
                    theme: theme, customText: custom?.configuration ?? "", showsPalette: hoveredTheme == hoverID
                )
                .frame(width: 108)
                Text(verbatim: custom?.name ?? theme.name).font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
    }
}

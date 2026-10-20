// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import GhosttyTheme
import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalThemeView: View {
    let model: TerminalSettingsModel
    let isDark: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hoveredTheme: String?

    private var options: TerminalThemeOptions {
        .init(preferences: model.preferences, isDark: isDark, library: model.themeLibrary)
    }

    var body: some View {
        MobileCardPage {
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
            TerminalThemeAvailabilityNotice(options: options)
            if !options.customThemes(matching: query).isEmpty {
                Text(AppStrings.Settings.customThemes).font(.headline)
                MobileCardGrid {
                    ForEach(options.customThemes(matching: query)) { theme in
                        tile(theme: theme.baseTheme, custom: theme)
                    }
                }
            }
            if !options.themes(matching: query).isEmpty {
                Text(AppStrings.Settings.builtInThemes).font(.headline)
                MobileCardGrid {
                    ForEach(options.themes(matching: query)) { theme in tile(theme: theme) }
                }
            } else if options.customThemes(matching: query).isEmpty {
                Text(AppStrings.Settings.noMatchingThemes).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(options.title)
        .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(AppStrings.Settings.searchThemes))
    }

    private func tile(theme: GhosttyThemeDefinition, custom: TerminalCustomTheme? = nil) -> some View {
        let hoverID = custom?.id.uuidString ?? theme.name
        let selected = custom.map { options.selectedCustomTheme?.id == $0.id } ?? options.isSelected(theme.name)
        return MobileActionCard(alignment: .leading) {
            let saved: Bool
            if let custom {
                saved = model.selectCustomTheme(id: custom.id, isDark: isDark)
            } else {
                saved = model.selectTheme(named: theme.name, isDark: isDark)
            }
            if saved { dismiss() }
        } content: {
            HStack(spacing: 12) {
                TerminalThemeThumbnail(
                    theme: theme, customText: custom?.configuration ?? "", showsPalette: hoveredTheme == hoverID
                )
                .frame(width: 96)
                Text(verbatim: custom?.name ?? theme.name).font(.headline)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true) }
            }
        } actions: {
        }
        .onHover { hovering in
            if hovering { hoveredTheme = hoverID } else if hoveredTheme == hoverID { hoveredTheme = nil }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

import GhosttyTheme
import SwiftUI
import TermindApplication
import TermindPresentation

struct MobileTerminalThemeView: View {
    let model: TerminalSettingsModel
    let isDark: Bool
    @State private var query = ""
    @State private var hoveredTheme: String?
    @State private var isEditing = false
    @State private var customText = ""
    @TerminalFontSettings private var font

    private var options: TerminalThemeOptions { .init(preferences: model.preferences, isDark: isDark) }

    var body: some View {
        MobileCardPage {
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
            TerminalThemeAvailabilityNotice(options: options)
            MobileCardGrid {
                ForEach(options.themes(matching: query)) { theme in
                    tile(theme: theme, custom: false)
                }

                tile(theme: options.baseTheme, custom: true)
            }
            if options.themes(matching: query).isEmpty {
                Text(AppStrings.Settings.noMatchingThemes).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(options.title)
        .searchable(text: $query, prompt: Text(AppStrings.Settings.searchThemes))
        .sheet(isPresented: $isEditing) {
            MobileEditorSheet(
                title: String(
                    localized: isDark
                        ? AppStrings.Settings.darkCustomConfiguration : AppStrings.Settings.lightCustomConfiguration),
                isDirty: customText != options.customText,
                save: {
                    guard model.set(customText, for: isDark ? \.darkCustomConfiguration : \.lightCustomConfiguration)
                    else { throw MobileEditorError.message(model.storageError ?? "") }
                }
            ) {
                Text(AppStrings.Settings.terminalConfigurationExplanation)
                    .font(.caption).foregroundStyle(.secondary)
                TerminalConfigurationEditorLayout {
                    TextEditor(text: $customText)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .frame(minHeight: 280)
                        .accessibilityLabel(AppStrings.Settings.customConfiguration.swiftUIKey)
                } preview: {
                    TerminalConfigurationPreview(
                        themeName: options.name, text: customText, isDark: isDark,
                        font: font.resolvingFamily(in: TerminalFontCatalog.shared.families))
                }
            }
        }
    }

    private func tile(theme: GhosttyThemeDefinition, custom: Bool) -> some View {
        let hoverID = custom ? "__custom__" : theme.name
        let selected = custom ? options.isCustom : options.isSelected(theme.name)
        return MobileActionCard {
            if custom {
                model.selectCustomTheme(isDark: isDark)
            } else {
                model.selectTheme(named: theme.name, isDark: isDark)
            }
        } content: {
            HStack(spacing: 12) {
                TerminalThemeThumbnail(
                    theme: theme, customText: custom ? options.customText : "", showsPalette: hoveredTheme == hoverID
                )
                .frame(width: 96)
                if custom {
                    Text(AppStrings.Settings.customTheme).font(.headline)
                } else {
                    Text(verbatim: theme.name).font(.headline)
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                }
            }
            .padding(.trailing, custom ? 32 : 0)
        } actions: {
            if custom {
                Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
                    customText = options.customText
                    isEditing = true
                }
            }
        }
        .onHover { hovering in
            if hovering { hoveredTheme = hoverID } else if hoveredTheme == hoverID { hoveredTheme = nil }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .overlay(alignment: .topTrailing) {
            if custom {
                Button {
                    customText = options.customText
                    isEditing = true
                } label: {
                    Label(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(4)
            }
        }
    }
}

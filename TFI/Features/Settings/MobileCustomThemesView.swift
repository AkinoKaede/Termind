import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileCustomThemesView: View {
    let model: TerminalSettingsModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var query = ""
    @State private var draft: TerminalCustomThemeDraft?
    @State private var deleting: TerminalCustomTheme?

    var body: some View {
        MobileCardPage {
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
            if model.themeLibrary.themes.isEmpty {
                ContentUnavailableView {
                    Label(AppStrings.Settings.customThemes.swiftUIKey, systemImage: "paintpalette")
                } description: {
                    Text(AppStrings.Settings.noCustomThemes)
                }
            } else if model.themeLibrary.themes(matching: query).isEmpty {
                ContentUnavailableView.search(text: query)
            }
            MobileCardGrid {
                ForEach(model.themeLibrary.themes(matching: query)) { theme in
                    MobileActionCard(alignment: .leading) {
                        draft = .init(theme, isNew: false)
                    } content: {
                        TerminalCustomThemeSummary(theme: theme, library: model.themeLibrary)
                            .padding(.trailing, 32)
                    } actions: {
                        actions(theme)
                    }
                    .overlay(alignment: .topTrailing) {
                        Menu {
                            actions(theme)
                        } label: {
                            Label(AppStrings.Common.edit.swiftUIKey, systemImage: "ellipsis")
                                .labelStyle(.iconOnly)
                                .frame(width: 44, height: 44).contentShape(.rect)
                        }
                        .padding(4)
                    }
                    .operationConfirmation(
                        .init(AppStrings.Settings.deleteCustomThemeConfirmation),
                        isPresented: $deleting.isPresenting { $0.id == theme.id },
                        actions: [
                            .init(AppStrings.Common.delete, role: .destructive) {
                                model.deleteCustomTheme(id: theme.id)
                                deleting = nil
                            },
                            .init(AppStrings.Common.cancel, role: .cancel) { deleting = nil },
                        ],
                        message: .init(AppStrings.Settings.deleteCustomThemeWarning)
                    )
                }
            }
        }
        .navigationTitle(AppStrings.Settings.customThemes.swiftUIKey)
        .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(AppStrings.Settings.searchThemes)
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let dark = colorScheme == .dark
                    let options = TerminalThemeOptions(
                        preferences: model.preferences, isDark: dark, library: model.themeLibrary)
                    draft = .init(
                        .init(name: "", appearance: dark ? .dark : .light, baseThemeName: options.baseTheme.name),
                        isNew: true)
                } label: {
                    Label(AppStrings.Settings.newCustomTheme.swiftUIKey, systemImage: "plus").labelStyle(.iconOnly)
                }
            }
        }
        .sheet(item: $draft) { draft in
            MobileCustomThemeEditorSheet(draft: draft, model: model)
        }
    }

    @ViewBuilder private func actions(_ theme: TerminalCustomTheme) -> some View {
        Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") {
            draft = .init(theme, isNew: false)
        }
        Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "doc.on.doc") {
            let copy = theme.copy(
                named: AppLocalization.resolve(AppStrings.Settings.customThemeCopy(theme.name), locale: locale))
            draft = .init(copy, isNew: true)
        }
        Divider()
        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) { deleting = theme }
    }
}

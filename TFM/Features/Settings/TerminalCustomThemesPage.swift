import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct TerminalCustomThemesPage: View {
    @Environment(AppModel.self) private var app
    @Environment(WindowModel.self) private var window
    @Environment(\.locale) private var locale
    @State private var deleting: TerminalCustomTheme?

    var body: some View {
        Group {
            if app.terminalSettings.themeLibrary.themes.isEmpty {
                ContentUnavailableView {
                    Label(AppStrings.Settings.customThemes.swiftUIKey, systemImage: "paintpalette")
                } description: {
                    Text(AppStrings.Settings.noCustomThemes)
                }
            } else if app.terminalSettings.themeLibrary.themes(matching: window.customThemeQuery).isEmpty {
                ContentUnavailableView {
                    Label(AppStrings.Settings.noMatchingThemes.swiftUIKey, systemImage: "magnifyingglass")
                }
            } else {
                CardPage {
                    CardGrid {
                        ForEach(app.terminalSettings.themeLibrary.themes(matching: window.customThemeQuery)) { theme in
                            CardTile(activate: { edit(theme) }, activatesOnReturn: true, activatesOnSingleClick: true) {
                                TerminalCustomThemeSummary(theme: theme, library: app.terminalSettings.themeLibrary)
                                    .padding(.trailing, 24)
                            }
                            .contextMenu { actions(theme) }
                            .overlay(alignment: .topTrailing) {
                                Menu {
                                    actions(theme)
                                } label: {
                                    Label(AppStrings.Common.edit.swiftUIKey, systemImage: "ellipsis").labelStyle(
                                        .iconOnly)
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .padding(10)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TermindColor.windowSurface)
        .safeAreaInset(edge: .top) {
            if let error = app.terminalSettings.storageError {
                Text(error).font(.caption).foregroundStyle(.red).padding()
            }
        }
        .alert(
            AppStrings.Settings.deleteCustomThemeConfirmation,
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                if let deleting { app.terminalSettings.deleteCustomTheme(id: deleting.id) }
                deleting = nil
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) { deleting = nil }
        } message: {
            Text(AppStrings.Settings.deleteCustomThemeWarning)
        }
    }

    @ViewBuilder private func actions(_ theme: TerminalCustomTheme) -> some View {
        Button(AppStrings.Common.edit.swiftUIKey, systemImage: "pencil") { edit(theme) }
        Button(AppStrings.Common.duplicate.swiftUIKey, systemImage: "doc.on.doc") {
            let copy = theme.copy(
                named: AppLocalization.resolve(AppStrings.Settings.customThemeCopy(theme.name), locale: locale))
            edit(copy, isNew: true)
        }
        Divider()
        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) { deleting = theme }
    }

    private func edit(_ theme: TerminalCustomTheme, isNew: Bool = false) {
        window.beginEditingTerminalTheme(theme, isNew: isNew, in: app.terminalSettings)
    }
}

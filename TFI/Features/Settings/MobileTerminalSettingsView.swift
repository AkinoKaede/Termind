import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalSettingsView: View {
    let model: TerminalSettingsModel
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            themeSection(dark: false)
            themeSection(dark: true)
            Section(AppStrings.Settings.font.swiftUIKey) {
                TerminalFontFields(preferences: $font, families: TerminalFontCatalog.shared.families)
            }
            Section(AppStrings.Settings.integration.swiftUIKey) {
                Toggle(AppStrings.Settings.shellIntegration.swiftUIKey, isOn: binding(\.shellIntegration))
            }
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(AppStrings.Settings.terminal.swiftUIKey)
        .onAppear { TerminalFontCatalog.shared.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
    }

    private func themeSection(dark: Bool) -> some View {
        let options = TerminalThemeOptions(preferences: model.preferences, isDark: dark)
        return Section {
            NavigationLink {
                MobileTerminalThemeView(model: model, isDark: dark)
            } label: {
                HStack {
                    Text(options.title)
                    Spacer()
                    options.summary.foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { _ = model.set($0, for: path) })
    }
}

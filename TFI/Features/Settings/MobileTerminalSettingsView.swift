import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalSettingsView: View {
    let model: TerminalSettingsModel
    let experience: TerminalExperienceSettingsModel
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    init(model: TerminalSettingsModel, experience: TerminalExperienceSettingsModel) {
        self.model = model
        self.experience = experience
    }

    var body: some View {
        Form {
            Section {
                Toggle(AppStrings.Settings.keepScreenAwake.swiftUIKey, isOn: experienceBinding(\.keepScreenAwake))
            }
            Section(AppStrings.Settings.theme.swiftUIKey) {
                themeRow(dark: false)
                themeRow(dark: true)
                NavigationLink {
                    MobileCustomThemesView(model: model)
                } label: {
                    Text(AppStrings.Settings.customThemes)
                }
            }
            Section(AppStrings.Settings.font.swiftUIKey) {
                TerminalFontFields(preferences: $font, families: TerminalFontCatalog.shared.families)
            }
            Section(AppStrings.Settings.bell.swiftUIKey) {
                Toggle(AppStrings.Settings.vibration.swiftUIKey, isOn: experienceBinding(\.bellVibration))
                Toggle(AppStrings.Settings.sound.swiftUIKey, isOn: experienceBinding(\.bellSound))
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

    private func themeRow(dark: Bool) -> some View {
        let options = TerminalThemeOptions(preferences: model.preferences, isDark: dark, library: model.themeLibrary)
        return NavigationLink {
            MobileTerminalThemeView(model: model, isDark: dark)
        } label: {
            HStack {
                Text(options.title)
                Spacer()
                options.summary.foregroundStyle(.secondary)
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { _ = model.set($0, for: path) })
    }

    private func experienceBinding(_ path: WritableKeyPath<TerminalExperiencePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { experience.preferences[keyPath: path] }, set: { experience.set($0, for: path) })
    }
}

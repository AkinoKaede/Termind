import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalSettingsView: View {
    let model: TerminalSettingsModel
    let notifications: any CommandNotificationSending
    @State private var editingDark: Bool?
    @State private var customText = ""
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            themeSection(dark: false)
            themeSection(dark: true)
            Section(AppStrings.Settings.font.swiftUIKey) {
                TerminalFontFields(preferences: $font, families: TerminalFontCatalog.shared.families)
            }
            TerminalCommandNotificationFields(
                model: model, service: notifications,
                openSettings: TerminalNotificationPlatform.openSettings)
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
        .sheet(isPresented: Binding(get: { editingDark != nil }, set: { if !$0 { editingDark = nil } })) {
            if let dark = editingDark {
                let original =
                    dark ? model.preferences.darkCustomConfiguration : model.preferences.lightCustomConfiguration
                MobileEditorSheet(
                    title: String(localized: AppStrings.Settings.customConfiguration), isDirty: customText != original,
                    save: {
                        guard model.set(customText, for: dark ? \.darkCustomConfiguration : \.lightCustomConfiguration)
                        else {
                            throw MobileEditorError.message(model.storageError ?? "")
                        }
                    },
                    content: {
                        TextEditor(text: $customText).multilineTextAlignment(.leading).font(
                            .system(.body, design: .monospaced)
                        )
                        .textInputAutocapitalization(.never).autocorrectionDisabled().frame(minHeight: 280)
                        .accessibilityLabel(AppStrings.Settings.customConfiguration.swiftUIKey)
                    })
            }
        }
    }

    private func themeSection(dark: Bool) -> some View {
        Section {
            TerminalThemePicker(selection: binding(dark ? \.darkTheme : \.lightTheme), isDark: dark)
            Toggle(
                AppStrings.Settings.customConfiguration.swiftUIKey,
                isOn: binding(dark ? \.darkCustomEnabled : \.lightCustomEnabled))
            Button(AppStrings.Settings.editConfiguration.swiftUIKey, systemImage: "pencil") {
                customText =
                    dark ? model.preferences.darkCustomConfiguration : model.preferences.lightCustomConfiguration
                editingDark = dark
            }
        } header: {
            Text(dark ? String(localized: AppStrings.Settings.dark) : String(localized: AppStrings.Settings.light))
        } footer: {
            if dark {
                Text(
                    AppStrings.Settings.terminalConfigurationExplanation
                )
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { _ = model.set($0, for: path) })
    }
}

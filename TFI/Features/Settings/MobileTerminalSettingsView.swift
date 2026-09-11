import SwiftUI
import TermindApplication
import TermindDomain

struct MobileTerminalSettingsView: View {
    let model: TerminalSettingsModel
    @State private var editingDark: Bool?
    @State private var customText = ""

    var body: some View {
        Form {
            Section("Font") {
                Toggle("Follow Theme", isOn: binding(\.fontFollowTheme))
                Stepper(value: binding(\.fontSize), in: 8...36, step: 1) {
                    LabeledContent("Font Size", value: model.preferences.fontSize.formatted())
                }.disabled(model.preferences.fontFollowTheme)
            }
            themeSection(dark: false)
            themeSection(dark: true)
            Section { Toggle("Shell Integration", isOn: binding(\.shellIntegration)) }
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Terminal")
        .sheet(isPresented: Binding(get: { editingDark != nil }, set: { if !$0 { editingDark = nil } })) {
            if let dark = editingDark {
                let original =
                    dark ? model.preferences.darkCustomConfiguration : model.preferences.lightCustomConfiguration
                MobileEditorSheet(
                    title: String(localized: "Custom Configuration"), isDirty: customText != original,
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
                        .accessibilityLabel("Custom Configuration")
                    })
            }
        }
    }

    private func themeSection(dark: Bool) -> some View {
        Section(dark ? String(localized: "Dark") : String(localized: "Light")) {
            Picker("Theme", selection: binding(dark ? \.darkTheme : \.lightTheme)) {
                ForEach(TermindTerminalThemeCatalog.allThemes.filter { $0.isDark == dark }, id: \.name) {
                    Text(verbatim: $0.name).tag($0.name)
                }
            }
            Toggle("Custom Configuration", isOn: binding(dark ? \.darkCustomEnabled : \.lightCustomEnabled))
            Button("Edit Configuration", systemImage: "pencil") {
                customText =
                    dark ? model.preferences.darkCustomConfiguration : model.preferences.lightCustomConfiguration
                editingDark = dark
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { _ = model.set($0, for: path) })
    }
}

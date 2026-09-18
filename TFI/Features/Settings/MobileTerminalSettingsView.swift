import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation

struct MobileTerminalSettingsView: View {
    let model: TerminalSettingsModel
    @State private var editingDark: Bool?
    @State private var customText = ""
    @TerminalFontSettings private var font
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("Font") {
                TerminalFontPicker(family: $font.family, families: TerminalFontCatalog.shared.families)
                Toggle("Font Size Follows Theme", isOn: $font.sizeFollowsTheme)
                Stepper(value: $font.size, in: 8...36, step: 1) {
                    LabeledContent("Font Size", value: font.size.formatted())
                }.disabled(font.sizeFollowsTheme)
            }
            themeSection(dark: false)
            themeSection(dark: true)
            Section("Integration") { Toggle("Shell Integration", isOn: binding(\.shellIntegration)) }
            if let error = model.storageError { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("Terminal")
        .onAppear { TerminalFontCatalog.shared.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { TerminalFontCatalog.shared.refresh() }
        }
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
        Section {
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
        } header: {
            Text(dark ? String(localized: "Dark") : String(localized: "Light"))
        } footer: {
            if dark {
                Text(
                    "Termind uses [Ghostty](https://ghostty.org) as its terminal engine. Custom configuration uses [Ghostty's configuration format](https://ghostty.org/docs/config/reference)."
                )
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<TerminalPreferences, Value>) -> Binding<Value> {
        Binding(get: { model.preferences[keyPath: path] }, set: { _ = model.set($0, for: path) })
    }
}

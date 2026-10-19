import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import UniformTypeIdentifiers

struct MobileCustomThemeEditorSheet: View {
    @Bindable var draft: TerminalCustomThemeDraft
    let model: TerminalSettingsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @TerminalFontSettings private var font
    @State private var importing = false
    @State private var deleting = false
    @State private var importError: String?

    var body: some View {
        MobileEditorSheet(
            title: AppLocalization.resolve(
                draft.isNew ? AppStrings.Settings.newCustomTheme : AppStrings.Settings.customThemes, locale: locale),
            isDirty: draft.isDirty,
            canSave: draft.value.isValid && !draft.isDeleted(in: model),
            actions: editorActions,
            discardQuestion: draft.isNew
                ? AppStrings.Settings.discardNewCustomThemeQuestion : AppStrings.Common.discardChangesQuestion,
            save: {
                guard draft.save(in: model) else {
                    throw MobileEditorError.message(
                        model.storageError ?? AppLocalization.resolve(AppStrings.Common.unableToSave, locale: locale))
                }
            }
        ) {
            Section {
                TextField(AppStrings.Common.name.swiftUIKey, text: $draft.value.name)
                Picker(AppStrings.Settings.appearance.swiftUIKey, selection: $draft.value.appearance) {
                    ForEach(TerminalThemeAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
            }
            Section {
                TerminalConfigurationEditorLayout {
                    TextEditor(text: $draft.value.configuration)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 280)
                        .accessibilityLabel(AppStrings.Settings.customConfiguration.swiftUIKey)
                } preview: {
                    TerminalConfigurationPreview(
                        themeName: draft.value.baseTheme.name, text: draft.value.configuration,
                        isDark: draft.value.baseTheme.isDark,
                        font: font.resolvingFamily(in: TerminalFontCatalog.shared.families))
                }
            } footer: {
                Text(AppStrings.Settings.terminalConfigurationExplanation)
            }
            if draft.isDeleted(in: model) {
                Section {
                    Button(AppStrings.Settings.saveThemeCopy.swiftUIKey, systemImage: "doc.on.doc") {
                        draft.makeCopy(
                            name: AppLocalization.resolve(
                                AppStrings.Settings.customThemeCopy(draft.value.name), locale: locale))
                        if draft.save(in: model) { dismiss() }
                    }
                    .disabled(!draft.value.isValid)
                } footer: {
                    Text(AppStrings.Settings.customThemeDeleted)
                }
            }
            if let error = importError ?? model.storageError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onChange(of: model.themeLibrary) { _, _ in draft.refresh(from: model) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
            do { try importFile(result.get()) } catch { importError = error.localizedDescription }
        }
        .operationConfirmation(
            .init(AppStrings.Settings.deleteCustomThemeConfirmation),
            isPresented: $deleting, placement: .centered,
            actions: [
                .init(AppStrings.Common.delete, role: .destructive) {
                    if model.deleteCustomTheme(id: draft.id) { dismiss() }
                },
                .init(AppStrings.Common.cancel, role: .cancel) {},
            ],
            message: .init(AppStrings.Settings.deleteCustomThemeWarning)
        )
    }

    private var editorActions: [MobileEditorToolbarAction] {
        var actions: [MobileEditorToolbarAction] = [
            .init(
                id: "import", title: AppStrings.Settings.importFromFile,
                systemImage: "square.and.arrow.down", perform: { importing = true })
        ]
        if !draft.isNew, !draft.isDeleted(in: model) {
            actions.append(
                .init(
                    id: "delete", title: AppStrings.Common.delete, systemImage: "trash",
                    role: .destructive, startsGroup: true, perform: { deleting = true }))
        }
        return actions
    }

    private func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            importError = AppLocalization.resolve(AppStrings.Settings.fileIsNotValidUtf8Text, locale: locale)
            return
        }
        draft.value.configuration = text
        importError = nil
    }
}

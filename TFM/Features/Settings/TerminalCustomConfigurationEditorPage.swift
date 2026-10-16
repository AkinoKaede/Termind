import SwiftUI
import TermindApplication
import TermindDomain
import TermindPresentation
import UniformTypeIdentifiers

struct TerminalCustomConfigurationEditorPage: View {
    @Bindable private var draft: TerminalCustomThemeDraft
    private let model: TerminalSettingsModel
    private let availableFontFamilies: [String]
    @Environment(WindowModel.self) private var window
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @TerminalFontSettings private var font
    @State private var importError: String?
    @State private var fieldsHeight: CGFloat = 0
    @State private var headingHeight: CGFloat = 0

    init(
        draft: TerminalCustomThemeDraft, model: TerminalSettingsModel, availableFontFamilies: [String] = []
    ) {
        self.draft = draft
        self.model = model
        self.availableFontFamilies = availableFontFamilies
    }

    var body: some View {
        @Bindable var window = window
        GeometryReader { geometry in
            let contentWidth = geometry.size.width - 8
            let sideBySide = contentWidth >= 700 && !typeSize.isAccessibilitySize
            let panelHeight = max(460, geometry.size.height - fieldsHeight - 24)
            let layout =
                sideBySide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    fields(width: contentWidth)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height
                        } action: {
                            fieldsHeight = $0
                        }
                    layout {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(AppStrings.Settings.customConfiguration)
                                .font(.headline)
                                .onGeometryChange(for: CGFloat.self) {
                                    $0.size.height
                                } action: {
                                    headingHeight = $0
                                }
                            TextEditor(text: $draft.value.configuration)
                                .font(.system(.body, design: .monospaced))
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .frame(maxWidth: .infinity)
                                .frame(height: sideBySide ? panelHeight - headingHeight - 12 : 360)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(.separator, lineWidth: 1)
                                        .allowsHitTesting(false)
                                }
                                .accessibilityLabel(AppStrings.Settings.customConfiguration.swiftUIKey)
                        }
                        .frame(maxWidth: .infinity)
                        TerminalConfigurationPreview(
                            themeName: draft.value.baseTheme.name, text: draft.value.configuration,
                            isDark: draft.value.baseTheme.isDark,
                            font: font.resolvingFamily(in: availableFontFamilies)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: sideBySide ? panelHeight : nil)
                    }
                }
                // Native text-field focus rings extend outside the control's layout bounds.
                .padding(4)
            }
        }
        .padding(12)
        .background(TermindColor.windowSurface)
        .onAppear {
            guard window.terminalThemeDraft === draft else { return }
            window.terminalThemeSettings = model
        }
        .task(id: draft.value) {
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            // A discarded or deleted draft must never be saved by a pending task.
            guard !Task.isCancelled, window.terminalThemeDraft === draft else { return }
            window.saveTerminalThemeChanges(allowNameTrimming: false)
        }
        .onChange(of: model.themeLibrary) { _, _ in draft.refresh(from: model) }
        .fileImporter(isPresented: $window.isImportingTerminalTheme, allowedContentTypes: [.plainText, .data]) {
            result in
            do { try importFile(result.get()) } catch { importError = error.localizedDescription }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            do { try importFile(url) } catch { importError = error.localizedDescription }
            return true
        }
        .alert(
            AppStrings.Settings.deleteCustomThemeConfirmation,
            isPresented: $window.isDeletingTerminalTheme
        ) {
            Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                guard model.deleteCustomTheme(id: draft.id) else { return }
                window.clearTerminalThemeEditor()
                window.settingsRoute = .terminalCustomThemes
            }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Settings.deleteCustomThemeWarning)
        }
    }

    private func fields(width: CGFloat) -> some View {
        let compact = width < 520 || typeSize.isAccessibilitySize
        let layout =
            compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
        return VStack(alignment: .leading, spacing: 12) {
            layout {
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppStrings.Common.name).font(.subheadline).foregroundStyle(.secondary)
                    TextField(AppStrings.Common.name.swiftUIKey, text: $draft.value.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("custom-theme-name")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Text(AppStrings.Settings.appearance).font(.subheadline).foregroundStyle(.secondary)
                    Picker(AppStrings.Settings.appearance.swiftUIKey, selection: $draft.value.appearance) {
                        ForEach(TerminalThemeAppearance.allCases, id: \.self) { appearance in
                            Text(appearance.title).tag(appearance)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("custom-theme-appearance")
                }
                .frame(minWidth: 150, maxWidth: compact ? .infinity : nil, alignment: .leading)
            }
            .controlSize(.regular)
            .frame(maxWidth: compact ? .infinity : 640, alignment: .leading)
            if TermindTerminalThemeCatalog.theme(named: draft.value.baseThemeName) == nil {
                Text(AppStrings.Settings.unavailableThemeFallback(draft.value.baseTheme.name))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if draft.isDeleted(in: model) {
                Text(AppStrings.Settings.customThemeDeleted).font(.caption).foregroundStyle(.orange)
                Button(AppStrings.Settings.saveThemeCopy.swiftUIKey, systemImage: "doc.on.doc") {
                    draft.makeCopy(
                        name: AppLocalization.resolve(
                            AppStrings.Settings.customThemeCopy(draft.value.name), locale: locale))
                    window.saveTerminalThemeChanges()
                }
                .disabled(!draft.value.isValid)
            }
            if let error = importError ?? model.storageError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Text(AppStrings.Settings.terminalConfigurationExplanation)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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

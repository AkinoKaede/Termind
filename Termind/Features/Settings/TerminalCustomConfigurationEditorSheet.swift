import SwiftUI
import UniformTypeIdentifiers

nonisolated enum TerminalCustomConfigurationScheme: String, Identifiable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    var settingsKey: String {
        switch self {
        case .light: SettingsKey.terminalCustomConfigurationLight
        case .dark: SettingsKey.terminalCustomConfigurationDark
        }
    }

    var title: String {
        switch self {
        case .light: String(localized: "Light Custom Configuration")
        case .dark: String(localized: "Dark Custom Configuration")
        }
    }
}

struct TerminalCustomConfigurationEditorSheet: View {
    let scheme: TerminalCustomConfigurationScheme

    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .textContentType(.none)
                .autocorrectionDisabled()
                .padding(Metrics.Space.m)
                .navigationTitle(scheme.title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Import from File") { isImporting = true }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            saveNow()
                            dismiss()
                        }
                    }
                }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onAppear {
            content = UserDefaults.standard.string(forKey: scheme.settingsKey) ?? ""
        }
        .onChange(of: content) { _, newValue in scheduleSave(newValue) }
        .onDisappear { saveNow() }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importFile(url)
            return true
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                importFile(url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )
        ) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        let key = scheme.settingsKey
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        UserDefaults.standard.set(content, forKey: scheme.settingsKey)
    }

    private func importFile(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let imported = String(data: data, encoding: .utf8) else {
                importError = String(localized: "File is not valid UTF-8 text")
                return
            }
            content = imported
        } catch {
            importError = error.localizedDescription
        }
    }
}

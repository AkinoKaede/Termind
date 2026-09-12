import SwiftUI
import TermindApplication
import TermindDomain
import UniformTypeIdentifiers

nonisolated enum TerminalCustomConfigurationScheme: String, Identifiable, Hashable, Sendable {
    case light
    case dark

    var id: String { rawValue }

    var preferenceKeyPath: WritableKeyPath<TerminalPreferences, String> {
        switch self {
        case .light: \.lightCustomConfiguration
        case .dark: \.darkCustomConfiguration
        }
    }

    var enabledKeyPath: WritableKeyPath<TerminalPreferences, Bool> {
        switch self {
        case .light: \.lightCustomEnabled
        case .dark: \.darkCustomEnabled
        }
    }

    var title: String {
        switch self {
        case .light: String(localized: "Light Custom Configuration")
        case .dark: String(localized: "Dark Custom Configuration")
        }
    }
}

struct TerminalCustomConfigurationEditorPage: View {
    @Environment(AppModel.self) private var app
    let scheme: TerminalCustomConfigurationScheme

    @State private var content = ""
    @State private var lastSavedContent = ""
    @State private var isLoaded = false
    @State private var isImporting = false
    @State private var importError: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            if let importError = importError ?? app.terminalSettings.storageError {
                HStack(spacing: Metrics.Space.m) {
                    Label(importError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button {
                        self.importError = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Dismiss error"))
                }
                .padding(.horizontal, Metrics.Space.xl)
                .padding(.vertical, Metrics.Space.s)
                .background(Color.orange.opacity(0.08))
                Divider()
            }

            HStack {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { app.terminalSettings.preferences[keyPath: scheme.enabledKeyPath] },
                        set: { app.terminalSettings.set($0, for: scheme.enabledKeyPath) })
                )
                .toggleStyle(.switch)
                Spacer()
                Button("Import from File") { isImporting = true }
            }
            .padding(.horizontal, Metrics.Space.l)
            .padding(.vertical, Metrics.Space.s)
            Divider()

            TextEditor(text: $content)
                .font(.system(.body, design: .monospaced))
                .textContentType(.none)
                .autocorrectionDisabled()
                .padding(Metrics.Space.m)
        }
        .onAppear {
            content = app.terminalSettings.preferences[keyPath: scheme.preferenceKeyPath]
            lastSavedContent = content
            isLoaded = true
        }
        .onChange(of: content) { _, newValue in scheduleSave(newValue) }
        .onChange(of: app.terminalSettings.preferences[keyPath: scheme.preferenceKeyPath]) { _, value in
            if content == lastSavedContent {
                lastSavedContent = value
                content = value
            }
        }
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
    }

    private func scheduleSave(_ value: String) {
        saveTask?.cancel()
        guard isLoaded, value != lastSavedContent else { return }
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if app.terminalSettings.set(value, for: scheme.preferenceKeyPath) { lastSavedContent = value }
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard isLoaded, content != lastSavedContent else { return }
        if app.terminalSettings.set(content, for: scheme.preferenceKeyPath) { lastSavedContent = content }
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

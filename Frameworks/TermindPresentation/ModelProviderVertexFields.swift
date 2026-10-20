// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import UniformTypeIdentifiers

/// Platform-independent fields; hosts own file access, secret transactions, and request lifetimes.
public struct ModelProviderVertexFields: View {
    @Binding private var isEnabled: Bool
    @Binding private var projectID: String
    @Binding private var location: String
    private let clientEmail: String
    private let hasCredential: Bool
    private let requestURL: String?
    private let readFile: (URL) async throws -> String
    private let importJSON: (String) throws -> Void
    private let remove: () throws -> Void
    @State private var importingFile = false
    @State private var pasting = false
    @State private var json = ""
    @State private var error: String?
    @State private var importTask: Task<Void, Never>?

    public init(
        isEnabled: Binding<Bool>, projectID: Binding<String>, location: Binding<String>,
        clientEmail: String, hasCredential: Bool, requestURL: String?,
        readFile: @escaping (URL) async throws -> String,
        importJSON: @escaping (String) throws -> Void, remove: @escaping () throws -> Void
    ) {
        _isEnabled = isEnabled
        _projectID = projectID
        _location = location
        self.clientEmail = clientEmail
        self.hasCredential = hasCredential
        self.requestURL = requestURL
        self.readFile = readFile
        self.importJSON = importJSON
        self.remove = remove
    }

    public var body: some View {
        Section("Google Vertex AI") {
            Toggle(AppStrings.Settings.vertexAi.swiftUIKey, isOn: $isEnabled)
            if isEnabled {
                LabeledContent("Project ID") {
                    TextField("Project ID", text: $projectID.singleLineText, axis: .horizontal)
                        .singleLinePaste().labelsHidden().multilineTextAlignment(.trailing)
                        .autocorrectionDisabled().lineLimit(1)
                }
                LabeledContent("Location") {
                    TextField(
                        "Location", text: $location.singleLineText, prompt: Text(verbatim: "global"), axis: .horizontal
                    )
                    .singleLinePaste().labelsHidden().multilineTextAlignment(.trailing)
                    .autocorrectionDisabled().lineLimit(1)
                }
                LabeledContent("Service Account") {
                    if hasCredential {
                        Text(clientEmail).textSelection(.enabled)
                    } else {
                        Text(AppStrings.Vault.required)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { credentialActions }
                    VStack(alignment: .leading, spacing: 12) { credentialActions }
                }
                .buttonStyle(.bordered)
                if let requestURL {
                    LabeledContent("Full URL") {
                        Text(requestURL).font(.caption.monospaced()).textSelection(.enabled)
                            .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("Enter a valid project and location to configure Vertex AI.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Vertex AI requires a service account. Add model IDs manually; model discovery is unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.json], allowsMultipleSelection: false) {
            result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                importTask?.cancel()
                importTask = Task {
                    do {
                        let value = try await readFile(url)
                        try Task.checkCancellation()
                        try importJSON(value)
                    } catch {
                        if !Task.isCancelled { self.error = error.localizedDescription }
                    }
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $pasting, onDismiss: { json = "" }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste Service Account JSON").font(.headline)
                TextEditor(text: $json).autohidingScrollers().font(.body.monospaced()).autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .frame(minHeight: 220)
                if let error { Text(error).foregroundStyle(.red) }
                HStack {
                    Button(AppStrings.Common.cancel.swiftUIKey) {
                        json = ""
                        pasting = false
                    }
                    Spacer()
                    Button(AppStrings.Common.import.swiftUIKey) {
                        perform {
                            try importJSON(json)
                            json = ""
                            pasting = false
                        }
                    }.disabled(json.isEmpty)
                }
            }
            .padding().frame(minWidth: 300, idealWidth: 520)
        }
        .onDisappear {
            importTask?.cancel()
            importTask = nil
            json = ""
        }
        .onChange(of: isEnabled) { _, _ in
            importTask?.cancel()
            importTask = nil
            json = ""
            pasting = false
        }
    }

    @ViewBuilder private var credentialActions: some View {
        Button(AppStrings.Common.import.swiftUIKey) {
            importTask?.cancel()
            error = nil
            importingFile = true
        }
        Button(AppStrings.Common.paste.swiftUIKey) {
            importTask?.cancel()
            error = nil
            json = ""
            pasting = true
        }
        if hasCredential {
            Button("Remove Service Account", role: .destructive) { perform(remove) }
        }
    }

    private func perform(_ action: () throws -> Void) {
        importTask?.cancel()
        do {
            try action()
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

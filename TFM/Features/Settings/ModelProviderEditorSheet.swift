import AgentKit
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation

@Observable
final class ModelProviderEditorSession {
    var secret = ""
    var name = ""
    var endpoint = ProviderEndpoint()
    var projectID = ""
    var location = ""
    var error: String?
    private var didBegin = false

    func begin(with provider: ModelProvider, in store: AIConfigurationModel, isNew: Bool = false) {
        guard !didBegin else { return }
        didBegin = true
        name = isNew ? "" : provider.name
        endpoint = isNew ? ProviderEndpoint() : store.endpoint(for: provider.id)
        projectID = provider.vertex.projectID
        location = isNew ? "" : provider.vertex.location
        secret = store.secret(for: provider.credentialRef) ?? ""
    }
}

/// Everything about one model provider: where it points, what it authenticates with,
/// and which models it offers.
///
/// Edits write through immediately. Models live on the next page, keeping both
/// jobs full-width and giving each a stable Back path instead of opening a sheet.
struct ModelProviderEditorPage: View {
    @Environment(\.locale) private var locale
    let modelProviderID: ModelProvider.ID
    var isNew = false
    let showModels: () -> Void
    let deleted: () -> Void

    @Environment(AppModel.self) private var app

    /// The API key as typed. Held here rather than read back out of the store,
    /// because the store hands out secrets through one accessor and a
    /// `SecureField` bound straight to it would put the key in the view's
    /// identity as well as in its buffer.
    @State private var session = ModelProviderEditorSession()

    private var provider: ModelProvider? { app.aiConfiguration.modelProvider(modelProviderID) }

    var body: some View {
        Group {
            if let provider {
                settings(provider)
            } else {
                ContentUnavailableView("Provider Deleted", systemImage: "trash")
            }
        }
        .onAppear(perform: loadSecrets)
    }

    private var brokenRoles: [AIRole] {
        app.aiConfiguration.roles(using: modelProviderID)
    }

    private var brokenRolesSummary: String {
        let names = brokenRoles.map(\.displayName).formatted(.list(type: .and).locale(locale))
        return String(localized: "\(names) would go back to Automatic.")
    }

    private var deleteHelp: Text {
        Text("Permanently deletes this provider, its key, and its models.")
    }

    // MARK: - Settings column

    private func settings(_ provider: ModelProvider) -> some View {
        Form {
            ModelProviderConnectionFields(
                name: Binding(get: { session.name }, set: saveName),
                endpoint: Binding(get: { session.endpoint }, set: saveEndpoint),
                isEnabled: Binding(
                    get: { app.aiConfiguration.modelProvider(modelProviderID)?.isEnabled ?? false },
                    set: { value in updateProvider { $0.isEnabled = value } }),
                showsEndpoint: !provider.usesVertexEndpoint)
            if !provider.usesVertexEndpoint { credentialSection }
            if session.endpoint.apiType == .generateContent { vertexSection(provider) }
            if let error = session.error { Text(error).foregroundStyle(.red) }

            Section("Models") {
                Button(action: showModels) {
                    HStack {
                        Label("Manage Models", systemImage: "cube")
                        Spacer()
                        Text(provider.models.count, format: .number)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            Section {
                Button("Delete", role: .destructive) {
                    app.aiConfiguration.delete(modelProviderID: modelProviderID)
                    deleted()
                }
                .help(deleteHelp)

                if !brokenRoles.isEmpty {
                    Text(brokenRolesSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var credentialSection: some View {
        Section {
            RevealableSecretField(
                "API Key",
                text: Binding(
                    get: { session.secret },
                    set: {
                        session.secret = $0
                        store(secret: $0)
                    }
                ),
                prompt: Text("Optional")
            )

            Text(
                "The key is stored in this Mac's Data Protection Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Secrets

    private func loadSecrets() {
        guard let provider else { return }
        session.begin(with: provider, in: app.aiConfiguration, isNew: isNew)
    }

    /// Mints a reference the first time something is typed, and clears the
    /// reference entirely when the field is emptied.
    ///
    /// Clearing the ref rather than storing an empty string is what makes
    /// `hasCredential` mean what it says: a provider pointing at a Keychain
    /// entry that holds nothing is not credentialled, and it should not look
    /// like it is.
    private func store(secret value: String) {
        guard let provider else { return }
        do {
            try saveCredential(provider, kind: .apiKey, replacement: value.isEmpty ? nil : value)
            session.error = nil
        } catch { session.error = error.localizedDescription }
    }

    private func saveName(_ value: String) {
        session.name = value
        guard var provider else { return }
        provider.name = value
        app.aiConfiguration.saveProvider(provider, endpoint: app.aiConfiguration.endpoint(for: modelProviderID))
    }

    private func saveEndpoint(_ value: ProviderEndpoint) {
        session.endpoint = value
        guard var provider else { return }
        if session.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { provider.name = "" }
        app.aiConfiguration.saveProvider(provider, endpoint: value)
    }

    private func vertexSection(_ provider: ModelProvider) -> some View {
        ModelProviderVertexFields(
            isEnabled: Binding(
                get: { provider.usesVertex },
                set: { value in
                    updateProvider { $0.usesVertex = value }
                }),
            projectID: Binding(
                get: { session.projectID },
                set: { value in
                    session.projectID = value
                    updateProvider { $0.vertex.projectID = value }
                }),
            location: Binding(
                get: { session.location },
                set: { value in
                    session.location = value
                    updateProvider { $0.vertex.location = value }
                }),
            clientEmail: provider.vertex.clientEmail, hasCredential: !provider.vertex.credentialRef.isEmpty,
            requestURL: ModelProviderForm.hasValidAddress(provider) ? provider.requestURL() : nil,
            readFile: { try await ModelProviderServiceAccountFile.read($0) },
            importJSON: { json in
                let account = try ModelProviderServiceAccount(json: json)
                guard var current = self.provider else { return }
                current.vertex.clientEmail = account.clientEmail
                if current.vertex.projectID.isEmpty { current.vertex.projectID = account.projectID }
                try saveCredential(current, kind: .serviceAccount, replacement: account.json)
                session.projectID = current.vertex.projectID
            },
            remove: {
                guard var current = self.provider else { return }
                current.vertex.clientEmail = ""
                try saveCredential(current, kind: .serviceAccount, replacement: nil)
            })
    }

    private func updateProvider(_ change: (inout ModelProvider) -> Void) {
        guard var provider else { return }
        change(&provider)
        app.aiConfiguration.saveProvider(provider, endpoint: app.aiConfiguration.endpoint(for: modelProviderID))
    }

    private func saveCredential(_ value: ModelProvider, kind: ModelProviderCredentialKind, replacement: String?) throws
    {
        let ai = app.aiConfiguration
        let reference = kind.reference(in: value)
        let previous = ai.secret(for: reference)
        if !reference.isEmpty, let error = ai.secretStorageError {
            throw AIConfigurationModel.CredentialError.message(error)
        }
        try ai.saveProvider(
            value, endpoint: ai.endpoint(for: value.id),
            credentials: [
                .init(kind: kind, reference: reference, previous: previous, replacement: replacement)
            ])
    }
}

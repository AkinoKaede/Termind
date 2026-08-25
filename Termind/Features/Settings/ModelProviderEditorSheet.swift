import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ModelProviderEditorSession {
    var secret = ""
    var serviceAccountJSON = ""
    var isImporting = false
    var importError: String?
    private var didBegin = false

    func begin(with provider: ModelProvider, in store: AIStore) {
        guard !didBegin else { return }
        didBegin = true
        secret = store.secret(for: provider.credentialRef) ?? ""
        serviceAccountJSON = store.secret(for: provider.vertex.credentialRef) ?? ""
    }
}

/// Everything about one model provider: where it points, what it authenticates with,
/// and which models it offers.
///
/// Edits write through immediately. Models live on the next page, keeping both
/// jobs full-width and giving each a stable Back path instead of opening a sheet.
struct ModelProviderEditorPage: View {
    let modelProviderID: ModelProvider.ID
    let back: () -> Void
    let showModels: () -> Void
    let deleted: () -> Void

    @Environment(AppModel.self) private var app

    /// The API key as typed. Held here rather than read back out of the store,
    /// because the store hands out secrets through one accessor and a
    /// `SecureField` bound straight to it would put the key in the view's
    /// identity as well as in its buffer.
    @State private var session = ModelProviderEditorSession()

    private var provider: ModelProvider? { app.ai.modelProvider(modelProviderID) }

    var body: some View {
        VStack(spacing: 0) {
            if let provider {
                SettingsDetailHeader(
                    backLabel: "Providers",
                    title: provider.name.isEmpty ? String(localized: "Model Provider") : provider.name,
                    subtitle: provider.resolvedBaseURL,
                    back: back
                )
                Divider()
                settings(provider)
            } else {
                ContentUnavailableView("Provider Deleted", systemImage: "trash")
            }
        }
        .onAppear(perform: loadSecrets)
    }

    private var brokenRoles: [AIRole] {
        app.ai.roles(using: modelProviderID)
    }

    private var brokenRolesSummary: String {
        let names = brokenRoles.map(\.displayName).formatted(.list(type: .and))
        return String(localized: "\(names) would go back to Automatic.")
    }

    private var deleteHelp: Text {
        Text("Permanently deletes this provider, its key, and its models.")
    }

    // MARK: - Settings column

    private func settings(_ provider: ModelProvider) -> some View {
        Form {
            Section {
                TextField("Name", text: binding(\.name))

                Picker("API Type", selection: binding(\.kind)) {
                    ForEach(ModelProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
            }

            if provider.usesVertex && provider.kind == .google {
                vertexSection(provider)
            } else {
                endpointSection(provider)
                credentialSection(provider)
            }

            if provider.kind == .google {
                Section {
                    Toggle("Use Vertex AI", isOn: binding(\.usesVertex))
                    Text(
                        "Vertex AI uses a service account, project, and location instead of an API key."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

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
                }
                .buttonStyle(.plain)
            }

            Section {
                Button("Delete Provider", role: .destructive) {
                    app.ai.delete(modelProviderID: modelProviderID)
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
        .frame(maxWidth: Metrics.SettingsPage.contentWidth)
        .frame(maxWidth: .infinity)
    }

    /// Base URL and API path, both blank with the real default as the
    /// placeholder, and the resolved URL underneath.
    ///
    /// That caption is the point of the whole section. "Does the base URL
    /// include `/v1`" is the question every client of this shape gets wrong, and
    /// the answer here is not a convention to memorise — it is printed, live,
    /// from the same computed property the request is built from.
    @ViewBuilder
    private func endpointSection(_ provider: ModelProvider) -> some View {
        Section {
            TextField(
                "Base URL",
                text: binding(\.baseURL),
                prompt: Text(provider.kind.defaultBaseURL)
            )

            TextField(
                "API Path",
                text: binding(\.apiPath),
                prompt: Text(provider.kind.defaultAPIPath(usesResponsesAPI: provider.usesResponsesAPI))
            )

            if provider.kind == .openAI {
                // Only OpenAI has two chat endpoints. A toggle that did nothing
                // on the other two would be noise in the place noise costs most.
                Toggle("Responses API", isOn: binding(\.usesResponsesAPI))
            }

            LabeledContent("Full URL") {
                Text(provider.resolvedRequestURL())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if provider.resolvedAPIPath.contains(ModelProvider.modelToken) {
                Text("\(ModelProvider.modelToken) is replaced with the model id.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Endpoint")
        }
    }

    @ViewBuilder
    private func credentialSection(_ provider: ModelProvider) -> some View {
        Section {
            SecureField(
                "API Key",
                text: Binding(
                    get: { session.secret }, set: { session.secret = $0 }
                ),
                prompt: Text("Required")
            )
            .onChange(of: session.secret) { _, value in store(secret: value) }

            Text(
                "The key is stored in this Mac's Data Protection Keychain."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Vertex replaces the endpoint *and* the credential, which is why it gets
    /// its own section rather than an extra field: with it on, there is no base
    /// URL to type — the address is derived from the project and the location.
    @ViewBuilder
    private func vertexSection(_ provider: ModelProvider) -> some View {
        Section {
            TextField("Project ID", text: binding(\.vertex.projectID))
            TextField("Location", text: binding(\.vertex.location), prompt: Text("global"))

            LabeledContent("Full URL") {
                Text(provider.resolvedRequestURL())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Vertex AI")
        }

        Section {
            if provider.vertex.clientEmail.isEmpty {
                Text("No service account yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Service Account") {
                    Text(provider.vertex.clientEmail)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack {
                Button("Import JSON") { session.isImporting = true }
                if !session.serviceAccountJSON.isEmpty {
                    Button("Remove", role: .destructive) { clearServiceAccount() }
                }
            }

            if let importError = session.importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Termind reads the account name and stores the remaining key data as a secret."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Credential")
        }
        .fileImporter(
            isPresented: Binding(
                get: { session.isImporting }, set: { session.isImporting = $0 }
            ),
            allowedContentTypes: [.json]
        ) { result in
            importServiceAccount(result)
        }
    }

    // MARK: - Secrets

    private func loadSecrets() {
        guard let provider else { return }
        session.begin(with: provider, in: app.ai)
    }

    /// Mints a reference the first time something is typed, and clears the
    /// reference entirely when the field is emptied.
    ///
    /// Clearing the ref rather than storing an empty string is what makes
    /// `hasCredential` mean what it says: a provider pointing at a Keychain
    /// entry that holds nothing is not credentialled, and it should not look
    /// like it is.
    private func store(secret value: String) {
        guard var provider else { return }
        if value.isEmpty {
            app.ai.setSecret(nil, for: provider.credentialRef)
            provider.credentialRef = ""
        } else {
            if provider.credentialRef.isEmpty {
                provider.credentialRef = AIStore.makeCredentialRef()
            }
            app.ai.setSecret(value, for: provider.credentialRef)
        }
        app.ai.upsert(provider)
    }

    private func importServiceAccount(_ result: Result<URL, any Error>) {
        session.importError = nil
        do {
            let url = try result.get()
            // The panel hands back a security-scoped URL; without the accessor
            // the read fails silently under the sandbox.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let json = try String(contentsOf: url, encoding: .utf8)
            guard let email = GoogleServiceAccountAuth.clientEmail(in: json) else {
                session.importError = GoogleAuthError.malformedServiceAccount.localizedDescription
                return
            }

            guard var provider else { return }
            if provider.vertex.credentialRef.isEmpty {
                provider.vertex.credentialRef = AIStore.makeCredentialRef("vertex")
            }
            provider.vertex.clientEmail = email
            // The file names the project it belongs to, so a field the user
            // would otherwise copy across by hand fills itself — and fills with
            // the value that matches the key rather than a different one.
            if provider.vertex.projectID.isEmpty,
                let project = GoogleServiceAccountAuth.projectID(in: json)
            {
                provider.vertex.projectID = project
            }
            app.ai.setSecret(json, for: provider.vertex.credentialRef)
            app.ai.upsert(provider)
            session.serviceAccountJSON = json
        } catch {
            session.importError = error.localizedDescription
        }
    }

    private func clearServiceAccount() {
        guard var provider else { return }
        app.ai.setSecret(nil, for: provider.vertex.credentialRef)
        provider.vertex.credentialRef = ""
        provider.vertex.clientEmail = ""
        app.ai.upsert(provider)
        session.serviceAccountJSON = ""
        session.importError = nil
    }

    // MARK: - Binding

    /// A two-way binding into the stored provider.
    ///
    /// Reads and writes go through `AIStore` rather than through a local copy,
    /// so the row behind the sheet updates as you type and there is no "apply"
    /// step that could be skipped. The `?? ModelProvider(name: "")` is unreachable
    /// while the sheet is up — the `if let` in `body` has already established
    /// the provider exists.
    private func binding<Value>(_ keyPath: WritableKeyPath<ModelProvider, Value>) -> Binding<Value> {
        Binding(
            get: { app.ai.modelProvider(modelProviderID)?[keyPath: keyPath] ?? ModelProvider(name: "")[keyPath: keyPath] },
            set: { newValue in
                guard var provider = app.ai.modelProvider(modelProviderID) else { return }
                provider[keyPath: keyPath] = newValue
                app.ai.upsert(provider)
            }
        )
    }
}

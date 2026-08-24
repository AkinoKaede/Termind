import SwiftUI
import UniformTypeIdentifiers

@Observable
final class ModelProviderEditorSession {
    private struct Snapshot {
        var provider: ModelProvider
        var key: String
        var serviceAccount: String
    }

    var secret = ""
    var serviceAccountJSON = ""
    var isImporting = false
    var importError: String?
    private var snapshot: Snapshot?

    func begin(with provider: ModelProvider, in store: AIStore) {
        guard snapshot == nil else { return }
        secret = store.secret(for: provider.credentialRef) ?? ""
        serviceAccountJSON = store.secret(for: provider.vertex.credentialRef) ?? ""
        snapshot = Snapshot(
            provider: provider, key: secret, serviceAccount: serviceAccountJSON
        )
    }

    func rollback(current: ModelProvider?, in store: AIStore, isNew: Bool) {
        guard let snapshot else { return }
        if isNew {
            store.delete(modelProviderID: snapshot.provider.id)
            return
        }
        if let current {
            if current.credentialRef != snapshot.provider.credentialRef {
                store.setSecret(nil, for: current.credentialRef)
            }
            if current.vertex.credentialRef != snapshot.provider.vertex.credentialRef {
                store.setSecret(nil, for: current.vertex.credentialRef)
            }
        }
        store.upsert(snapshot.provider)
        store.setSecret(
            snapshot.key.isEmpty ? nil : snapshot.key,
            for: snapshot.provider.credentialRef
        )
        store.setSecret(
            snapshot.serviceAccount.isEmpty ? nil : snapshot.serviceAccount,
            for: snapshot.provider.vertex.credentialRef
        )
    }
}

/// Everything about one model provider: where it points, what it authenticates with,
/// and which models it offers.
///
/// Edits are written to the store as they are made rather than gathered and
/// applied on Done: the model list is edited here too, and a Fetch whose result
/// only landed on Done would be a button that appeared to do nothing.
///
/// Cancel therefore has to undo rather than discard. The provider and its
/// secrets are snapshotted on appear and put back if Cancel is pressed — and a
/// provider that only exists because Add Model Provider made it is removed outright,
/// so backing out of a mistyped provider leaves no half-built row behind. A
/// button labelled Cancel that only closed the window would be a lie, and the
/// one place it would be found out is after somebody fetched eighty models by
/// accident.
///
/// The sheet is wider and taller than `CreateSheet` because it holds a form and
/// a list at once. See `Metrics.EditorSheet`.
struct ModelProviderEditorSheet: View {
    let modelProviderID: ModelProvider.ID

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// The API key as typed. Held here rather than read back out of the store,
    /// because the store hands out secrets through one accessor and a
    /// `SecureField` bound straight to it would put the key in the view's
    /// identity as well as in its buffer.
    @State private var session = ModelProviderEditorSession()

    private var provider: ModelProvider? { app.ai.modelProvider(modelProviderID) }

    /// Whether this sheet is looking at a provider that was created to be
    /// filled in. Cancel deletes one of those rather than restoring it to the
    /// empty shell it started as.
    var isNew: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            if let provider {
                header(provider)
                Divider()
                HStack(spacing: 0) {
                    settings(provider)
                    Divider()
                    ModelListEditor(modelProviderID: modelProviderID)
                        .frame(width: Metrics.EditorSheet.listWidth)
                }
                Divider()
                footer(provider)
            } else {
                // The provider was deleted from under the sheet — by the delete
                // button below, which dismisses, or in another window.
                ContentUnavailableView("Provider Deleted", systemImage: "trash")
            }
        }
        .frame(width: Metrics.EditorSheet.width, height: Metrics.EditorSheet.height)
        .onAppear(perform: loadSecrets)
    }

    // MARK: - Chrome

    private func header(_ provider: ModelProvider) -> some View {
        HStack(spacing: Metrics.Space.m) {
            CardIcon(symbol: provider.kind.symbol)
            Text(provider.name.isEmpty ? String(localized: "Model Provider") : provider.name)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: Metrics.Space.m)
        }
        .padding(Metrics.Space.xl)
    }

    private func footer(_ provider: ModelProvider) -> some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Delete Provider", role: .destructive) {
                app.ai.delete(modelProviderID: modelProviderID)
                dismiss()
            }
            .help(deleteHelp)

            // Spelled out beside the button rather than hidden behind a
            // confirmation, so the cost is visible before the click instead of
            // after it. Same job `KeyCard`'s dependent count does.
            if !brokenRoles.isEmpty {
                Text(brokenRolesSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Metrics.Space.m)

            Button("Cancel", action: revert)
                .keyboardShortcut(.cancelAction)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.Space.l)
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

                Picker("API type", selection: binding(\.kind)) {
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
        }
        .formStyle(.grouped)
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
                "API path",
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
                "API key",
                text: Binding(
                    get: { session.secret }, set: { session.secret = $0 }
                ),
                prompt: Text("Required")
            )
            .onChange(of: session.secret) { _, value in store(secret: value) }

            Text(
                "The key stays in memory on this Mac and is cleared when Termind quits."
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
                LabeledContent("Service account") {
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

    /// Undoes everything this sheet did, then closes.
    private func revert() {
        defer { dismiss() }
        session.rollback(current: provider, in: app.ai, isNew: isNew)
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

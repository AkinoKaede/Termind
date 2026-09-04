import AgentKit
import SwiftUI

@Observable
final class ModelProviderEditorSession {
    var secret = ""
    private var didBegin = false

    func begin(with provider: ModelProvider, in store: AIConfigurationModel) {
        guard !didBegin else { return }
        didBegin = true
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
            Section {
                TextField("Name", text: binding(\.name))

                Picker("API Type", selection: endpointBinding(\.apiType)) {
                    ForEach(ModelAPIType.allCases) { Text($0.displayName).tag($0) }
                }
            }

            endpointSection
            credentialSection

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
                Button("Delete Provider", role: .destructive) {
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

    /// One address, and the two facts derived from it.
    ///
    /// One field rather than a base and a path, because splitting them made
    /// "does the base URL include `/v1`" a question the user had to answer —
    /// and it is the question every client of this shape gets wrong. Here they
    /// paste whatever their gateway's documentation printed, at whatever depth
    /// it printed it, and the two captions say what that produced.
    ///
    /// The captions are the point of the section. `Full URL` is read from the
    /// same value the request is built from, so it cannot drift from where
    /// requests land; the line under it names the body shape, which is how
    /// `Automatic` explains its own answer and how an explicit pick that
    /// disagrees with the URL stops being a silent surprise.
    @ViewBuilder
    private var endpointSection: some View {
        let endpoint = endpoint

        Section {
            TextField(
                "URL",
                text: endpointBinding(\.url),
                prompt: Text(verbatim: "https://ai.termind.akinokaede.com/v1")
            )

            if endpoint.isConfigured {
                LabeledContent("Full URL") {
                    Text(endpoint.requestURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Requests use the \(endpoint.format.displayName) format.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if endpoint.requestURL.contains(ModelProvider.modelToken) {
                    Text("\(ModelProvider.modelToken) is replaced with the model id.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Endpoint")
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
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

    // MARK: - Secrets

    private func loadSecrets() {
        guard let provider else { return }
        session.begin(with: provider, in: app.aiConfiguration)
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
            app.aiConfiguration.setSecret(nil, for: provider.credentialRef)
            provider.credentialRef = ""
        } else {
            if provider.credentialRef.isEmpty {
                provider.credentialRef = AIConfigurationModel.makeCredentialRef()
            }
            app.aiConfiguration.setSecret(value, for: provider.credentialRef)
        }
        app.aiConfiguration.upsert(provider)
    }

    // MARK: - Binding

    private var endpoint: ProviderEndpoint {
        app.aiConfiguration.endpoint(for: modelProviderID)
    }

    /// A two-way binding into the endpoint, written through the store's one
    /// derivation so the composed URL and the API format are updated together.
    private func endpointBinding<Value>(
        _ keyPath: WritableKeyPath<ProviderEndpoint, Value>
    ) -> Binding<Value> {
        Binding(
            get: { endpoint[keyPath: keyPath] },
            set: { newValue in
                var updated = endpoint
                updated[keyPath: keyPath] = newValue
                app.aiConfiguration.setEndpoint(updated, for: modelProviderID)
            }
        )
    }

    /// A two-way binding into the stored provider.
    ///
    /// Reads and writes go through `AIConfigurationModel` rather than through a local copy,
    /// so the row behind the sheet updates as you type and there is no "apply"
    /// step that could be skipped. The `?? ModelProvider(name: "")` is unreachable
    /// while the sheet is up — the `if let` in `body` has already established
    /// the provider exists.
    private func binding<Value>(_ keyPath: WritableKeyPath<ModelProvider, Value>) -> Binding<Value> {
        Binding(
            get: {
                app.aiConfiguration.modelProvider(modelProviderID)?[keyPath: keyPath]
                    ?? ModelProvider(name: "")[keyPath: keyPath]
            },
            set: { newValue in
                guard var provider = app.aiConfiguration.modelProvider(modelProviderID) else { return }
                provider[keyPath: keyPath] = newValue
                app.aiConfiguration.upsert(provider)
            }
        )
    }
}

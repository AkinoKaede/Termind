import SwiftUI

/// The "Web Search" section: how the assistant finds a URL, as the counterpart
/// to `fetch` reading one.
///
/// A form rather than a collection, because there is one backend rather than a
/// list of them. Two backends configured at once would raise a question — which
/// one runs? — that nothing here would be able to answer better than the user
/// picking.
struct WebSearchSettings: View {
    @Environment(AppModel.self) private var app

    @AppStorage(SettingsKey.webSearchEnabled) private var isEnabled =
        SettingsKey.defaultWebSearchEnabled
    @AppStorage(SettingsKey.webSearchBackend) private var backendID = SearchBackend.default.rawValue
    @AppStorage(SettingsKey.webSearchBaseURL) private var baseURL = ""
    @AppStorage(SettingsKey.webSearchCredentialRef) private var credentialRef = ""

    @State private var apiKey = ""
    @State private var probe: ProbeState = .idle

    private enum ProbeState: Equatable {
        case idle
        case running
        case succeeded(Int)
        case failed(String)
    }

    private var backend: SearchBackend {
        SearchBackend(rawValue: backendID) ?? .default
    }

    private var client: WebSearchClient {
        WebSearchClient(backend: backend, baseURL: baseURL, apiKey: apiKey)
    }

    var body: some View {
        Group {
            Section {
                Toggle("Enable Web Search", isOn: $isEnabled)

                Text(
                    "Models that can search on their own do so directly, and no backend below is "
                        + "used for them. Everything else gets a web_search tool backed by the "
                        + "backend below. Either way the assistant reads a result page with fetch."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Web Search")
            }

            Section {
                Picker("Backend", selection: $backendID) {
                    ForEach(SearchBackend.allCases) { option in
                        Text(option.displayName).tag(option.rawValue)
                    }
                }

                TextField("Base URL", text: $baseURL, prompt: Text(backend.defaultBaseURL))

                LabeledContent("Full URL") {
                    Text(client.resolvedURL)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if backend.requiresAPIKey {
                    SecureField("API Key", text: $apiKey, prompt: Text("Required"))
                        .onChange(of: apiKey) { _, value in store(key: value) }
                }

                Text(backend.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if backend.requiresAPIKey {
                    Text("The key is stored in this Mac's Data Protection Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Backend")
            }
            .disabled(!isEnabled)

            Section {
                // A real query against the real endpoint. The offline checks
                // cannot tell a working key from a wrong one, and for the
                // keyless backend they cannot tell working markup from markup
                // that moved — which is exactly what this button is for.
                Button("Test Search") { runProbe() }
                    .disabled(probe == .running || !isEnabled || !client.isConfigured)

                switch probe {
                case .idle:
                    EmptyView()
                case .running:
                    Label("Searching…", systemImage: "ellipsis.circle")
                        .font(.caption).foregroundStyle(.secondary)
                case .succeeded(let count):
                    Label(
                        count == 0
                            ? String(localized: "Reached the backend, but it returned no results.")
                            : String(localized: "\(count) results."),
                        systemImage: count == 0 ? "exclamationmark.triangle" : "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(count == 0 ? .orange : .green)
                case .failed(let reason):
                    Label(reason, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!isEnabled)
        }
        .onAppear { apiKey = app.ai.secret(for: credentialRef) ?? "" }
        .onChange(of: backendID) { _, _ in probe = .idle }
    }

    private func store(key: String) {
        guard !key.isEmpty else {
            app.ai.setSecret(nil, for: credentialRef)
            credentialRef = ""
            return
        }
        if credentialRef.isEmpty { credentialRef = AIStore.makeCredentialRef("search") }
        app.ai.setSecret(key, for: credentialRef)
    }

    private func runProbe() {
        probe = .running
        let client = client
        Task {
            do {
                let results = try await client.search("termind web search test", count: 3)
                probe = .succeeded(results.count)
            } catch {
                probe = .failed(error.localizedDescription)
            }
        }
    }
}

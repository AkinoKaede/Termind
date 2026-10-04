import AgentKit
import SwiftUI
import TermindApplication
import TermindPresentation

@Observable
final class MCPServerEditorSession {
    enum ConnectionState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    var token = ""
    var clientSecret = ""
    var task: Task<Void, Never>?
    var generation = UUID()
    var connection: ConnectionState = .idle
    private var didBegin = false

    func begin(with server: MCPServer, in store: AIConfigurationModel) {
        guard !didBegin else { return }
        didBegin = true
        token = store.secret(for: server.credentialRef) ?? ""
        do { clientSecret = try store.mcpAuthorization.clientSecret(for: server) } catch {
            connection = .failed(error.localizedDescription)
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        connection = .idle
    }
}

/// One MCP server: how to reach it, and what it turned out to offer.
///
/// The tool list is the important half. It only exists after a successful
/// Connect, because it is what the server said rather than what the user typed —
/// and each row carries a local policy for whether the tool is denied, follows
/// the conversation's approval mode, or runs without another approval. New
/// non-destructive tools carrying `readOnlyHint == true` begin approved; every
/// other new tool begins by asking, and rediscovery preserves the user's choice.
///
/// Edits write straight through and the page returns to the MCP list in place.
struct MCPServerEditorPage: View {
    @Environment(\.locale) private var locale
    let serverID: MCPServer.ID
    let deleted: () -> Void

    @Environment(AppModel.self) private var app

    @State private var session = MCPServerEditorSession()
    @State private var browser = MCPWebAuthenticationPresenter()

    private var server: MCPServer? { app.aiConfiguration.mcpServer(serverID) }

    private var namespaceID: String { server?.effectiveNamespaceID ?? "" }

    private var isNameEmpty: Bool {
        server?.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    private var hasNamespaceConflict: Bool {
        guard !namespaceID.isEmpty else { return false }
        return app.aiConfiguration.hasMCPNamespaceConflict(namespaceID, excluding: serverID)
    }

    var body: some View {
        Group {
            if let server {
                Form {
                    connectionSection(server)
                    credentialSection
                    oauthSection(server)
                    headersSection(server)
                    toolsSection(server)
                    Section {
                        Button(AppStrings.Common.delete.swiftUIKey, role: .destructive) {
                            app.aiConfiguration.delete(serverID: serverID)
                            deleted()
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView(AppStrings.Settings.serverDeleted.swiftUIKey, systemImage: "trash")
            }
        }
        .background(MCPAuthorizationAnchor(presenter: browser).frame(width: 0, height: 0))
        .onDisappear {
            session.cancel()
            browser.cancel()
        }
        .onChange(of: server?.url) { _, _ in
            session.cancel()
            browser.cancel()
            session.clientSecret = ""
        }
        .onChange(of: server?.transport) { _, _ in
            session.cancel()
            browser.cancel()
        }
        .onChange(of: server?.headers) { _, _ in
            session.cancel()
            browser.cancel()
        }
        .onChange(of: server?.oauth) { _, _ in
            session.cancel()
            browser.cancel()
            session.clientSecret = ""
        }
        .onAppear {
            guard let server else { return }
            session.begin(with: server, in: app.aiConfiguration)
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func connectionSection(_ server: MCPServer) -> some View {
        Section {
            TextField(AppStrings.Common.name.swiftUIKey, text: binding(\.name).singleLineText, axis: .horizontal)
                .singleLinePaste().lineLimit(1)
            Toggle(
                AppStrings.Common.enabled.swiftUIKey,
                isOn: Binding(
                    get: { app.aiConfiguration.mcpServer(serverID)?.isEnabled ?? false },
                    set: {
                        guard app.proAccess.require(.remoteMCP) else { return }
                        app.aiConfiguration.setServerEnabled($0, for: serverID)
                    }))

            LabeledContent(AppStrings.Settings.id.swiftUIKey) {
                Text(namespaceID)
                    .font(.callout.monospaced())
                    .foregroundStyle(namespaceID.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            if isNameEmpty {
                Label(AppStrings.Settings.nameIsRequired.swiftUIKey, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if namespaceID.isEmpty {
                Label(
                    AppStrings.Settings.namespaceNameRequirement.swiftUIKey,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if hasNamespaceConflict {
                Label(
                    AppStrings.Settings.anotherMcpServerAlreadyUsesThisId.swiftUIKey,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Picker(AppStrings.Settings.transport.swiftUIKey, selection: binding(\.transport)) {
                ForEach(MCPServer.Transport.allCases) { Text($0.displayName).tag($0) }
            }

            TextField(
                AppStrings.Settings.url.swiftUIKey, text: binding(\.url).singleLineText,
                prompt: Text(AppStrings.Settings.mcpEndpointUrl), axis: .horizontal
            )
            .singleLinePaste()
            .lineLimit(1)

            connectRow(server)
        } header: {
            Text(AppStrings.Settings.connection)
        }
    }

    @ViewBuilder
    private func connectRow(_ server: MCPServer) -> some View {
        HStack(spacing: Metrics.Space.m) {
            Button(AppStrings.Common.connect.swiftUIKey) { connect(server) }
                .disabled(
                    !server.isReachable || namespaceID.isEmpty || hasNamespaceConflict
                        || session.connection == .running
                )

            switch session.connection {
            case .idle:
                if let connected = server.lastConnectedAt {
                    Text(
                        AppStrings.Settings.lastConnected(
                            connected.formatted(.relative(presentation: .named).locale(locale)))
                    )
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
            case .running:
                ProgressView().controlSize(.small)
            case .succeeded(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(2)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var credentialSection: some View {
        Section {
            RevealableSecretField(
                AppStrings.Settings.bearerToken,
                text: $session.token,
                prompt: Text(AppStrings.Common.optional)
            )
            .onChange(of: session.token) { _, value in store(token: value) }

            Text(
                AppStrings.Settings.bearerTokenExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text(AppStrings.Settings.credential)
        }
    }

    @ViewBuilder
    private func oauthSection(_ server: MCPServer) -> some View {
        Section {
            let signedIn = app.aiConfiguration.mcpAuthorization.isSignedIn(server)
            Label(
                (signedIn ? AppStrings.MCP.oauthSignedIn : AppStrings.MCP.oauthSignedOut).swiftUIKey,
                systemImage: signedIn ? "checkmark.circle" : "person.crop.circle")
            HStack {
                Button((signedIn ? AppStrings.MCP.oauthReauthorize : AppStrings.MCP.oauthSignIn).swiftUIKey) {
                    session.task = Task {
                        if signedIn { await app.aiConfiguration.mcpAuthorization.prepareReauthorization(server) }
                        guard !Task.isCancelled else { return }
                        connect(server)
                    }
                }
                .disabled(!server.isReachable || session.connection == .running || hasManualAuthorization(server))
                if signedIn {
                    Button(AppStrings.MCP.oauthSignOut.swiftUIKey) {
                        session.cancel()
                        browser.cancel()
                        Task { await app.aiConfiguration.mcpAuthorization.signOut(server) }
                    }
                }
            }
            Text(AppStrings.MCP.oauthDeviceOnly).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup(AppStrings.MCP.oauthAdvanced.swiftUIKey) {
                TextField(
                    AppStrings.MCP.oauthIssuer.swiftUIKey, text: oauthBinding(\.issuer),
                    prompt: Text(AppStrings.MCP.oauthAutomatic))
                TextField(
                    AppStrings.MCP.oauthClientID.swiftUIKey, text: oauthBinding(\.clientID),
                    prompt: Text(AppStrings.Common.optional))
                RevealableSecretField(
                    AppStrings.MCP.oauthClientSecret, text: $session.clientSecret,
                    prompt: Text(AppStrings.Common.optional)
                )
                .onChange(of: session.clientSecret) { _, value in
                    session.cancel()
                    browser.cancel()
                    do { try app.aiConfiguration.mcpAuthorization.setClientSecret(value, for: server) } catch {
                        session.connection = .failed(error.localizedDescription)
                    }
                }
            }
            if let error = app.aiConfiguration.mcpAuthorization.error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text(AppStrings.MCP.oauth)
        }
    }

    private func hasManualAuthorization(_ server: MCPServer) -> Bool {
        !session.token.isEmpty || !server.credentialRef.isEmpty
            || server.headers.contains { $0.isComplete && $0.name.lowercased() == "authorization" }
    }

    private func oauthBinding(_ path: WritableKeyPath<MCPOAuthConfiguration, String>) -> Binding<String> {
        Binding(
            get: { server?.oauth?[keyPath: path] ?? "" },
            set: { value in
                guard var server else { return }
                var configuration = server.oauth ?? .init()
                configuration[keyPath: path] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                server.oauth = configuration.issuer.isEmpty && configuration.clientID.isEmpty ? nil : configuration
                app.aiConfiguration.upsert(server)
            })
    }

    @ViewBuilder
    private func headersSection(_ server: MCPServer) -> some View {
        Section {
            ForEach(server.headers) { header in
                HStack(spacing: Metrics.Space.s) {
                    TextField(
                        AppStrings.Common.name.swiftUIKey, text: headerBinding(header.id, \.name).singleLineText,
                        prompt: Text(AppStrings.Settings.headerName),
                        axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                    TextField(
                        AppStrings.Common.value.swiftUIKey, text: headerBinding(header.id, \.value).singleLineText,
                        prompt: Text(AppStrings.Settings.headerValue),
                        axis: .horizontal
                    ).singleLinePaste().lineLimit(1)
                    Button {
                        removeHeader(header.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(AppStrings.Settings.removeHeader))
                }
                .labelsHidden()
            }

            FormNavigationAction(title: AppStrings.Settings.addHeader, action: addHeader)
        } header: {
            Text(AppStrings.Settings.customHeaders)
        }
    }

    @ViewBuilder
    private func toolsSection(_ server: MCPServer) -> some View {
        Section {
            if server.tools.isEmpty {
                Text(AppStrings.Settings.connectToSeeWhatThisServerOffers)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.tools) { tool in
                    ToolRow(tool: tool, serverID: serverID)
                }
            }
        } header: {
            Text(AppStrings.Settings.tools)
        } footer: {
            if !server.tools.isEmpty {
                Text(
                    AppStrings.Settings.toolApprovalExplanation
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func connect(_ target: MCPServer) {
        guard !namespaceID.isEmpty, !hasNamespaceConflict else { return }
        guard app.aiConfiguration.lockMCPNamespace(for: serverID), let server else { return }
        session.cancel()
        let generation = session.generation
        session.connection = .running
        app.aiConfiguration.setMCPStatus(.connecting, for: serverID)
        let bearer = session.token.isEmpty ? nil : session.token

        session.task = Task {
            do {
                let discovery = try await app.aiConfiguration.mcpAuthorization.client
                    .discover(server, bearerToken: bearer, interaction: browser.interaction)
                guard !Task.isCancelled, generation == session.generation,
                    app.aiConfiguration.mcpServer(serverID) == server
                else { return }
                app.aiConfiguration.setTools(discovery.tools, version: discovery.protocolVersion, for: serverID)
                app.aiConfiguration.setMCPStatus(.connected, for: serverID)
                session.connection = .succeeded(
                    String(
                        localized: AppStrings.Settings.discoveredTools(
                            server: discovery.serverName, count: discovery.tools.count))
                )
            } catch {
                guard !Task.isCancelled, generation == session.generation else { return }
                if error is CancellationError {
                    app.aiConfiguration.setMCPStatus(.disconnected, for: serverID)
                    session.connection = .idle
                    return
                }
                app.aiConfiguration.setMCPStatus(.failed(error.localizedDescription), for: serverID)
                session.connection = .failed(error.localizedDescription)
            }
        }
    }

    private func store(token value: String) {
        session.cancel()
        browser.cancel()
        guard var server else { return }
        if value.isEmpty {
            app.aiConfiguration.setSecret(nil, for: server.credentialRef)
            server.credentialRef = ""
        } else {
            if server.credentialRef.isEmpty {
                server.credentialRef = AIConfigurationModel.makeCredentialRef("mcp")
            }
            app.aiConfiguration.setSecret(value, for: server.credentialRef)
        }
        app.aiConfiguration.upsert(server)
    }

    private func addHeader() {
        guard var server else { return }
        server.headers.append(MCPHeader())
        app.aiConfiguration.upsert(server)
    }

    private func removeHeader(_ id: MCPHeader.ID) {
        guard var server else { return }
        server.headers.removeAll { $0.id == id }
        app.aiConfiguration.upsert(server)
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<MCPServer, Value>) -> Binding<Value> {
        Binding(
            get: {
                app.aiConfiguration.mcpServer(serverID)?[keyPath: keyPath] ?? MCPServer(name: "")[keyPath: keyPath]
            },
            set: { newValue in
                guard var server = app.aiConfiguration.mcpServer(serverID) else { return }
                server[keyPath: keyPath] = newValue
                app.aiConfiguration.upsert(server)
            }
        )
    }

    private func headerBinding(
        _ id: MCPHeader.ID, _ keyPath: WritableKeyPath<MCPHeader, String>
    ) -> Binding<String> {
        Binding(
            get: { app.aiConfiguration.mcpServer(serverID)?.headers.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var server = app.aiConfiguration.mcpServer(serverID),
                    let index = server.headers.firstIndex(where: { $0.id == id })
                else { return }
                server.headers[index][keyPath: keyPath] = newValue
                app.aiConfiguration.upsert(server)
            }
        )
    }
}

// MARK: - Tool row

/// One discovered tool and the local policy applied when the model calls it.
private struct ToolRow: View {
    let tool: MCPTool
    let serverID: MCPServer.ID

    @Environment(AppModel.self) private var app

    private var qualifiedToolName: String {
        guard let server = app.aiConfiguration.mcpServer(serverID) else { return tool.id }
        let leaf =
            MCPToolNaming.functionNames(for: server.tools)[tool.id]
            ?? MCPToolNaming.functionName(from: tool.id)
        return MCPToolNaming.qualifiedName(
            namespace: server.effectiveNamespaceID, function: leaf
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(qualifiedToolName)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !tool.summary.isEmpty {
                    Text(tool.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            Picker(AppStrings.Common.permission.swiftUIKey, selection: permission) {
                ForEach(AgentToolDescriptor.ApprovalPolicy.allCases) { option in
                    Text(option.displayName)
                        .tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(Text(AppStrings.Common.permission))
        }
        .frame(maxWidth: .infinity)
        .font(.caption)
        .help(Text(tool.summary.isEmpty ? qualifiedToolName : tool.summary))
    }

    private var permission: Binding<AgentToolDescriptor.ApprovalPolicy> {
        Binding(
            get: { tool.accessPolicy },
            set: { policy in
                app.aiConfiguration.setToolAccessPolicy(policy, tool: tool.id, on: serverID)
            }
        )
    }
}

extension AgentToolDescriptor.ApprovalPolicy {
    fileprivate var displayName: LocalizedStringResource {
        switch self {
        case .deny: AppStrings.Common.deny
        case .ask: AppStrings.Settings.ask
        case .approve: AppStrings.Settings.approve
        }
    }
}

import SwiftUI

@Observable
final class MCPServerEditorSession {
    enum ConnectionState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    var token = ""
    var connection: ConnectionState = .idle
    private var didBegin = false

    func begin(with server: MCPServer, in store: AIConfigurationModel) {
        guard !didBegin else { return }
        didBegin = true
        token = store.secret(for: server.credentialRef) ?? ""
    }
}

/// One MCP server: how to reach it, and what it turned out to offer.
///
/// The tool list is the important half. It only exists after a successful
/// Connect, because it is what the server said rather than what the user typed —
/// and each row carries two switches, one for whether the tool is offered to the
/// model at all and one for whether calling it needs a click.
///
/// That second switch defaults to on and is the reason this sheet is worth
/// building now rather than at P3. Termind's whole premise is that nothing runs
/// without the user's say-so; a tool list fetched over the network from a server
/// the model can also talk to is precisely where that premise would spring a
/// leak if approval were opt-in.
///
/// Edits write straight through and the page returns to the MCP list in place.
struct MCPServerEditorPage: View {
    let serverID: MCPServer.ID
    let isNew: Bool
    let back: () -> Void
    let deleted: () -> Void

    @Environment(AppModel.self) private var app

    @State private var session = MCPServerEditorSession()

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
        VStack(spacing: 0) {
            if let server {
                SettingsDetailHeader(
                    backLabel: "MCP",
                    title: server.name.isEmpty ? String(localized: "Server") : server.name,
                    subtitle: server.negotiatedVersion.isEmpty ? server.url : "MCP \(server.negotiatedVersion)",
                    back: back,
                    trailing: AnyView(StatusDot(status: app.aiConfiguration.mcpStatus(of: serverID)))
                )
                Divider()
                Form {
                    connectionSection(server)
                    credentialSection
                    headersSection(server)
                    toolsSection(server)
                    Section {
                        Button("Delete Server", role: .destructive) {
                            app.aiConfiguration.delete(serverID: serverID)
                            deleted()
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(maxWidth: Metrics.SettingsPage.contentWidth)
                .frame(maxWidth: .infinity)
            } else {
                ContentUnavailableView("Server Deleted", systemImage: "trash")
            }
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
            TextField("Name", text: binding(\.name))

            LabeledContent("ID") {
                Text(namespaceID)
                    .font(.callout.monospaced())
                    .foregroundStyle(namespaceID.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
            }

            if isNameEmpty {
                Label("Name is required.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if namespaceID.isEmpty {
                Label("Name must produce an ID containing ASCII letters or numbers.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if hasNamespaceConflict {
                Label("Another MCP server already uses this ID.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Picker("Transport", selection: binding(\.transport)) {
                ForEach(MCPServer.Transport.allCases) { Text($0.displayName).tag($0) }
            }

            TextField("URL", text: binding(\.url), prompt: Text("MCP endpoint URL"))

            Text(server.transport.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            connectRow(server)
        } header: {
            Text("Connection")
        }
    }

    @ViewBuilder
    private func connectRow(_ server: MCPServer) -> some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Connect") { connect(server) }
                .disabled(
                    !server.isReachable || namespaceID.isEmpty || hasNamespaceConflict
                        || session.connection == .running
                )

            switch session.connection {
            case .idle:
                if let connected = server.lastConnectedAt {
                    Text("Last connected \(connected.formatted(.relative(presentation: .named)))")
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
            SecureField(
                "Bearer Token",
                text: Binding(get: { session.token }, set: { session.token = $0 }),
                prompt: Text("Optional")
            )
            .onChange(of: session.token) { _, value in store(token: value) }

            Text(
                "Sent in the Authorization header. Custom headers below are stored as plain text."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Credential")
        }
    }

    @ViewBuilder
    private func headersSection(_ server: MCPServer) -> some View {
        Section {
            ForEach(server.headers) { header in
                HStack(spacing: Metrics.Space.s) {
                    TextField(
                        "Name", text: headerBinding(header.id, \.name), prompt: Text("Header name"))
                    TextField(
                        "Value", text: headerBinding(header.id, \.value), prompt: Text("Header value"))
                    Button {
                        removeHeader(header.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Remove header"))
                }
                .labelsHidden()
            }

            FormNavigationAction(title: "Add Header", action: addHeader)
        } header: {
            Text("Custom Headers")
        } footer: {
            Text("For secrets, use the bearer token field above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func toolsSection(_ server: MCPServer) -> some View {
        Section {
            if server.tools.isEmpty {
                Text("Connect to see what this server offers.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.tools) { tool in
                    ToolRow(tool: tool, serverID: serverID)
                }
            }
        } header: {
            Text("Tools")
        } footer: {
            if !server.tools.isEmpty {
                Text(
                    "With Ask First on, you approve each call. Turn it off only for trusted, read-only tools."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func connect(_ server: MCPServer) {
        guard !namespaceID.isEmpty, !hasNamespaceConflict else { return }
        guard app.aiConfiguration.lockMCPNamespace(for: serverID) else { return }
        session.connection = .running
        app.aiConfiguration.setMCPStatus(.connecting, for: serverID)
        let bearer = session.token.isEmpty ? nil : session.token

        Task {
            do {
                let discovery = try await MCPClient().discover(server, bearerToken: bearer)
                app.aiConfiguration.setTools(discovery.tools, version: discovery.protocolVersion, for: serverID)
                app.aiConfiguration.setMCPStatus(.connected, for: serverID)
                session.connection = .succeeded(
                    discovery.tools.count == 1
                        ? String(localized: "\(discovery.serverName) — 1 tool")
                        : String(localized: "\(discovery.serverName) — \(discovery.tools.count) tools"))
            } catch {
                app.aiConfiguration.setMCPStatus(.failed(error.localizedDescription), for: serverID)
                session.connection = .failed(error.localizedDescription)
            }
        }
    }

    private func store(token value: String) {
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
            get: { app.aiConfiguration.mcpServer(serverID)?[keyPath: keyPath] ?? MCPServer(name: "")[keyPath: keyPath] },
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

/// One discovered tool, with its two switches.
///
/// "Ask First" rather than "Requires Approval": the label describes what will
/// happen to you, not the internal state.
private struct ToolRow: View {
    let tool: MCPTool
    let serverID: MCPServer.ID

    @Environment(AppModel.self) private var app

    private var qualifiedToolName: String {
        guard let server = app.aiConfiguration.mcpServer(serverID) else { return tool.id }
        let leaf = MCPToolNaming.functionNames(for: server.tools)[tool.id]
            ?? MCPToolNaming.functionName(from: tool.id)
        return MCPToolNaming.qualifiedName(
            namespace: server.effectiveNamespaceID, function: leaf
        )
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Space.m) {
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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Metrics.Space.m)

            Toggle("Offer", isOn: enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()

            Toggle("Ask First", isOn: asksFirst)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                // Greyed rather than hidden when the tool is off: the setting
                // still exists and comes back with it, and a control that
                // vanishes reads as one that was reset.
                .disabled(!tool.isEnabled)
        }
        .font(.caption)
        .help(Text(tool.summary.isEmpty ? qualifiedToolName : tool.summary))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { tool.isEnabled },
            set: { app.aiConfiguration.setToolEnabled($0, tool: tool.id, on: serverID) }
        )
    }

    private var asksFirst: Binding<Bool> {
        Binding(
            get: { tool.requiresApproval },
            set: { app.aiConfiguration.setToolRequiresApproval($0, tool: tool.id, on: serverID) }
        )
    }
}

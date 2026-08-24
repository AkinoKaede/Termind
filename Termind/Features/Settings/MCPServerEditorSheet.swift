import SwiftUI

@Observable
final class MCPServerEditorSession {
    enum ConnectionState: Equatable {
        case idle
        case running
        case succeeded(String)
        case failed(String)
    }

    private struct Snapshot {
        var server: MCPServer
        var token: String
    }

    var token = ""
    var connection: ConnectionState = .idle
    private var snapshot: Snapshot?

    func begin(with server: MCPServer, in store: AIStore) {
        guard snapshot == nil else { return }
        token = store.secret(for: server.credentialRef) ?? ""
        snapshot = Snapshot(server: server, token: token)
    }

    func rollback(current: MCPServer?, in store: AIStore, isNew: Bool) {
        guard let snapshot else { return }
        if isNew {
            store.delete(serverID: snapshot.server.id)
            return
        }
        if let current, current.credentialRef != snapshot.server.credentialRef {
            store.setSecret(nil, for: current.credentialRef)
        }
        store.upsert(snapshot.server)
        store.setSecret(
            snapshot.token.isEmpty ? nil : snapshot.token,
            for: snapshot.server.credentialRef
        )
        store.setMCPStatus(.disconnected, for: snapshot.server.id)
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
/// Edits write straight through, so Cancel undoes rather than discards — the
/// same contract as `ModelProviderEditorSheet`, for the same reason.
struct MCPServerEditorSheet: View {
    let serverID: MCPServer.ID
    /// True only when Add Server made this row, so Cancel removes it rather
    /// than restoring the empty shell it started as.
    var isNew: Bool = false

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var session = MCPServerEditorSession()

    private var server: MCPServer? { app.ai.mcpServer(serverID) }

    var body: some View {
        VStack(spacing: 0) {
            if let server {
                header(server)
                Divider()
                Form {
                    connectionSection(server)
                    credentialSection
                    headersSection(server)
                    toolsSection(server)
                }
                .formStyle(.grouped)
                Divider()
                footer
            } else {
                ContentUnavailableView("Server Deleted", systemImage: "trash")
            }
        }
        .frame(width: Metrics.EditorSheet.width, height: Metrics.EditorSheet.height)
        .onAppear {
            guard let server else { return }
            session.begin(with: server, in: app.ai)
        }
    }

    // MARK: - Chrome

    private func header(_ server: MCPServer) -> some View {
        HStack(spacing: Metrics.Space.m) {
            CardIcon(symbol: "wrench.and.screwdriver.fill", tint: .purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name.isEmpty ? String(localized: "Server") : server.name)
                    .font(.headline)
                    .lineLimit(1)
                if !server.negotiatedVersion.isEmpty {
                    Text("MCP \(server.negotiatedVersion)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: Metrics.Space.m)
            StatusDot(status: app.ai.mcpStatus(of: serverID))
        }
        .padding(Metrics.Space.xl)
    }

    private var footer: some View {
        HStack(spacing: Metrics.Space.m) {
            Button("Delete Server", role: .destructive) {
                app.ai.delete(serverID: serverID)
                dismiss()
            }
            Spacer(minLength: Metrics.Space.m)

            Button("Cancel", action: revert)
                .keyboardShortcut(.cancelAction)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.Space.l)
    }

    /// Undoes everything this sheet did, then closes. A discovered tool list is
    /// part of that: connecting is an edit like any other here.
    private func revert() {
        defer { dismiss() }
        session.rollback(current: server, in: app.ai, isNew: isNew)
    }

    // MARK: - Sections

    @ViewBuilder
    private func connectionSection(_ server: MCPServer) -> some View {
        Section {
            TextField("Name", text: binding(\.name))

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
                .disabled(!server.isReachable || session.connection == .running)

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
                "Bearer token",
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

            Button("Add Header") { addHeader() }
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
                    "With Ask first on, you approve each call. Turn it off only for trusted, read-only tools."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions

    private func connect(_ server: MCPServer) {
        session.connection = .running
        app.ai.setMCPStatus(.connecting, for: serverID)
        let bearer = session.token.isEmpty ? nil : session.token

        Task {
            do {
                let discovery = try await MCPClient().discover(server, bearerToken: bearer)
                app.ai.setTools(discovery.tools, version: discovery.protocolVersion, for: serverID)
                app.ai.setMCPStatus(.connected, for: serverID)
                session.connection = .succeeded(
                    discovery.tools.count == 1
                        ? String(localized: "\(discovery.serverName) — 1 tool")
                        : String(localized: "\(discovery.serverName) — \(discovery.tools.count) tools"))
            } catch {
                app.ai.setMCPStatus(.failed(error.localizedDescription), for: serverID)
                session.connection = .failed(error.localizedDescription)
            }
        }
    }

    private func store(token value: String) {
        guard var server else { return }
        if value.isEmpty {
            app.ai.setSecret(nil, for: server.credentialRef)
            server.credentialRef = ""
        } else {
            if server.credentialRef.isEmpty {
                server.credentialRef = AIStore.makeCredentialRef("mcp")
            }
            app.ai.setSecret(value, for: server.credentialRef)
        }
        app.ai.upsert(server)
    }

    private func addHeader() {
        guard var server else { return }
        server.headers.append(MCPHeader())
        app.ai.upsert(server)
    }

    private func removeHeader(_ id: MCPHeader.ID) {
        guard var server else { return }
        server.headers.removeAll { $0.id == id }
        app.ai.upsert(server)
    }

    // MARK: - Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<MCPServer, Value>) -> Binding<Value> {
        Binding(
            get: { app.ai.mcpServer(serverID)?[keyPath: keyPath] ?? MCPServer(name: "")[keyPath: keyPath] },
            set: { newValue in
                guard var server = app.ai.mcpServer(serverID) else { return }
                server[keyPath: keyPath] = newValue
                app.ai.upsert(server)
            }
        )
    }

    private func headerBinding(
        _ id: MCPHeader.ID, _ keyPath: WritableKeyPath<MCPHeader, String>
    ) -> Binding<String> {
        Binding(
            get: { app.ai.mcpServer(serverID)?.headers.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { newValue in
                guard var server = app.ai.mcpServer(serverID),
                    let index = server.headers.firstIndex(where: { $0.id == id })
                else { return }
                server.headers[index][keyPath: keyPath] = newValue
                app.ai.upsert(server)
            }
        )
    }
}

// MARK: - Tool row

/// One discovered tool, with its two switches.
///
/// "Ask first" rather than "Requires approval": the label describes what will
/// happen to you, not the internal state. The same reason the inline suggestion
/// overlay says Insert and Run rather than naming a risk level.
private struct ToolRow: View {
    let tool: MCPTool
    let serverID: MCPServer.ID

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.Space.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.id)
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

            Toggle("Ask first", isOn: asksFirst)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                // Greyed rather than hidden when the tool is off: the setting
                // still exists and comes back with it, and a control that
                // vanishes reads as one that was reset.
                .disabled(!tool.isEnabled)
        }
        .font(.caption)
        .help(Text(tool.summary.isEmpty ? tool.id : tool.summary))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { tool.isEnabled },
            set: { app.ai.setToolEnabled($0, tool: tool.id, on: serverID) }
        )
    }

    private var asksFirst: Binding<Bool> {
        Binding(
            get: { tool.requiresApproval },
            set: { app.ai.setToolRequiresApproval($0, tool: tool.id, on: serverID) }
        )
    }
}

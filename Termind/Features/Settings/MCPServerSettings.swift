import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

struct MCPServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsToken = false
    @State private var historyQuery = ""

    private var server: MCPServerController { app.mcpServer }

    var body: some View {
        Section("Server") {
            Toggle(
                "Enable",
                isOn: Binding(
                    get: { server.isEnabled && app.proAccess.canUse(.mcpServer) },
                    set: { server.setEnabled($0) }
                ))

            LabeledContent("Status") {
                HStack(spacing: Metrics.Space.s) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(server.status.label).foregroundStyle(.secondary)
                }
            }
            LabeledContent("Connected clients", value: "\(server.connectedClients)")
            LabeledContent("Port") {
                TextField(
                    "Port",
                    value: Binding(
                        get: { server.port },
                        set: { server.setPort($0) }
                    ), format: .number.grouping(.never)
                )
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
            }
            Text(
                "The server listens only on 127.0.0.1 and ::1. It is off by default; when enabled, external calls execute without per-call approval."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Bearer Token") {
            LabeledContent("Token") {
                HStack {
                    Text(showsToken ? displayToken : String(repeating: "•", count: 24))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button(showsToken ? "Hide" : "Show") { showsToken.toggle() }
                    Button("Copy") { copy(displayToken) }
                }
            }
            HStack {
                Button(displayToken.isEmpty ? "Generate Token" : "Rotate Token") {
                    server.rotateToken()
                    showsToken = true
                }
                if !displayToken.isEmpty {
                    Text("Rotating disconnects every active MCP session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        clientSetupSection

        Section("Exposed Tools") {
            ForEach(MCPServerTools.exportedNames.sorted(), id: \.self) { name in
                Toggle(
                    name,
                    isOn: Binding(
                        get: { !server.disabledTools.contains(name) },
                        set: { server.setToolEnabled($0, name: name) }
                    )
                )
                .font(.system(.body, design: .monospaced))
            }
            Text(
                "Tool changes are enforced immediately. Existing clients see the new list when they reconnect or list tools again."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("Call History") {
            TextField("Filter by client, tool, host or argument", text: $historyQuery)
            let rows = app.toolAudit.entries(matching: historyQuery)
            if rows.isEmpty {
                ContentUnavailableView(
                    "No external calls", systemImage: "clock.arrow.circlepath",
                    description: Text("Calls appear here after an MCP client invokes a tool.")
                )
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                ForEach(rows.prefix(200)) { row in ExternalToolCallRow(row: row) }
            }
            HStack {
                Button("Clear History", role: .destructive) { app.toolAudit.clear() }
                Spacer()
                Text("Stores commands, paths and byte counts; never file bodies, stdin, stdout or stderr.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayToken: String { server.token }

    private var clientSetupSection: some View {
        let setup = MCPClientSetupCommand(
            port: server.port, token: displayToken,
            bridgePath: Bundle.main.url(forAuxiliaryExecutable: "termind-mcp")?.path
        )
        let preview = MCPClientSetupCommand(
            port: setup.port, token: showsToken ? setup.token : "••••••••",
            bridgePath: setup.bridgePath
        )
        return Section("Connect Clients") {
            ForEach(MCPClientSetupCommand.Client.allCases) { client in
                let command = setup.command(for: client)
                HStack(spacing: Metrics.Space.m) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                        Text(verbatim: client.rawValue)
                        if command != nil, let detail = preview.command(for: client) {
                            Text(verbatim: detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(text: command ?? "", title: "Copy Add Command")
                        .disabled(command == nil)
                        .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                if displayToken.isEmpty {
                    Text("Generate a token to copy client setup commands.")
                }
                if setup.bridgePath == nil {
                    Text("The bundled MCP bridge is missing. Codex and Hermes setup commands are unavailable.")
                }
                Text("Run the copied command in a terminal on this Mac. Enable the server before connecting.")
                Text("Hermes needs the server running during setup and may ask you to select tools.")
                Text(
                    "Update client configurations after changing the port or token, or after moving Termind for Codex and Hermes."
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .ready: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private func copy(_ value: String) {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
}

private struct ExternalToolCallRow: View {
    let row: ExternalToolCall

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.m) {
            Image(systemName: statusSymbol).foregroundStyle(statusColor)
                .frame(width: Metrics.Sidebar.rowIcon)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(row.toolName).font(.system(.body, design: .monospaced))
                    if let host = row.hostDisplayName { Text(host).foregroundStyle(.secondary) }
                    Spacer()
                    Text(row.risk.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(row.summary.isEmpty ? row.clientName : row.summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(row.clientName)
                    Text(row.startedAt, style: .relative)
                    if let duration = row.duration {
                        Text(duration, format: .number.precision(.fractionLength(2))) + Text("s")
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var statusSymbol: String {
        switch row.status {
        case .running: "circle.dotted"
        case .ok: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        case .denied: "hand.raised.circle.fill"
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .running: .orange
        case .ok: .green
        case .error: .red
        case .denied: .secondary
        }
    }
}

import SwiftUI

#if canImport(AppKit)
    import AppKit
#endif

struct ToolServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var revealsToken = false
    @State private var historyQuery = ""

    private var server: ToolServerController { app.toolServer }

    var body: some View {
        Section("Server") {
            Toggle("Enable Tool Server", isOn: Binding(
                get: { server.isEnabled },
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
                TextField("Port", value: Binding(
                    get: { server.port },
                    set: { server.setPort($0) }
                ), format: .number.grouping(.never))
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
                    Text(revealsToken ? displayToken : String(repeating: "•", count: 24))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button(revealsToken ? "Hide" : "Reveal") { revealsToken.toggle() }
                    Button("Copy") { copy(displayToken) }
                }
            }
            HStack {
                Button(displayToken.isEmpty ? "Generate Token" : "Rotate Token") {
                    server.rotateToken()
                    revealsToken = true
                }
                if !displayToken.isEmpty {
                    Text("Rotating disconnects every active MCP session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section("Connect") {
            commandRow("Claude Code — HTTP", command: httpCommand)
            commandRow("Claude Code — stdio", command: stdioCommand)
        }

        Section("Exposed Tools") {
            ForEach(MCPToolServer.exportedNames.sorted(), id: \.self) { name in
                Toggle(name, isOn: Binding(
                    get: { !server.disabledTools.contains(name) },
                    set: { server.setToolEnabled($0, name: name) }
                ))
                .font(.system(.body, design: .monospaced))
            }
            Text("Tool changes are enforced immediately. Existing clients see the new list when they reconnect or list tools again.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Call History") {
            TextField("Filter by client, tool, host or argument", text: $historyQuery)
            let rows = app.externalToolCalls.entries(matching: historyQuery)
            if rows.isEmpty {
                ContentUnavailableView(
                    "No external calls", systemImage: "clock.arrow.circlepath",
                    description: Text("Calls appear here after an MCP client invokes a tool.")
                )
                .frame(minHeight: 120)
            } else {
                ForEach(rows.prefix(200)) { row in ExternalToolCallRow(row: row) }
            }
            HStack {
                Button("Clear History", role: .destructive) { app.externalToolCalls.clear() }
                Spacer()
                Text("Stores commands, paths and byte counts; never file bodies, stdin, stdout or stderr.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var displayToken: String { server.token }

    private var statusColor: Color {
        switch server.status {
        case .ready: .green
        case .starting: .orange
        case .failed: .red
        case .stopped: .secondary
        }
    }

    private var httpCommand: String {
        "claude mcp add --transport http termind http://127.0.0.1:\(server.port)/mcp --header \"Authorization: Bearer \(displayToken)\""
    }

    private var stdioCommand: String {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/termind-mcp").path
        return "claude mcp add termind -- \(shellQuote(executable)) --url http://127.0.0.1:\(server.port)/mcp --token \(shellQuote(displayToken))"
    }

    private func commandRow(_ title: LocalizedStringKey, command: String) -> some View {
        LabeledContent(title) {
            HStack {
                Text(command)
                    .font(.caption.monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button("Copy") { copy(command) }
            }
        }
    }

    private func copy(_ value: String) {
        #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        #endif
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
                    if let duration = row.duration { Text(duration, format: .number.precision(.fractionLength(2))) + Text("s") }
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

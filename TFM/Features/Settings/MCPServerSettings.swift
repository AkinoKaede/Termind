import SwiftUI
import TermindDomain
import TermindPresentation

#if canImport(AppKit)
    import AppKit
#endif

struct MCPServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsToken = false
    @State private var historyQuery = ""
    @State private var confirmsHistoryClear = false

    private var server: MCPServerController { app.mcpServer }

    var body: some View {
        Section(TermindCopy.Settings.server.swiftUIKey) {
            Toggle(
                TermindCopy.Settings.enable.swiftUIKey,
                isOn: Binding(
                    get: { server.isEnabled && app.proAccess.canUse(.mcpServer) },
                    set: { server.setEnabled($0) }
                ))

            LabeledContent(TermindCopy.Common.status.swiftUIKey) {
                HStack(spacing: Metrics.Space.s) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(server.status.label).foregroundStyle(.secondary)
                }
            }
            LabeledContent(TermindCopy.Settings.connectedClients.swiftUIKey, value: "\(server.connectedClients)")
            LabeledContent(TermindCopy.Common.port.swiftUIKey) {
                TextField(
                    TermindCopy.Common.port.swiftUIKey,
                    value: Binding(
                        get: { server.port },
                        set: { server.setPort($0) }
                    ), format: .number.grouping(.never)
                ).lineLimit(1)
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
            Text(
                TermindCopy.Settings.mcpServerAccessExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(TermindCopy.Settings.bearerToken.swiftUIKey) {
            LabeledContent(TermindCopy.Settings.token.swiftUIKey) {
                HStack {
                    Text(showsToken ? displayToken : String(repeating: "•", count: 24))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Button {
                        showsToken.toggle()
                    } label: {
                        Image(systemName: showsToken ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        showsToken
                            ? TermindCopy.Settings.hideSecret.swiftUIKey : TermindCopy.Settings.showSecret.swiftUIKey)
                    Button(TermindCopy.Common.copy.swiftUIKey) { copy(displayToken) }
                }
            }
            HStack {
                Button(
                    displayToken.isEmpty
                        ? TermindCopy.Settings.generateToken.swiftUIKey : TermindCopy.Settings.rotateToken.swiftUIKey
                ) {
                    server.rotateToken()
                    showsToken = true
                }
                if !displayToken.isEmpty {
                    Text(TermindCopy.Settings.rotatingDisconnectsEveryActiveMcpSession)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = server.tokenStorageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        clientSetupSection

        Section(TermindCopy.Settings.exposedTools.swiftUIKey) {
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
                TermindCopy.Settings.mcpToolChangesExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(TermindCopy.Settings.callHistory.swiftUIKey) {
            TextField(
                TermindCopy.Settings.filterByClientToolHostOrArgument.swiftUIKey, text: $historyQuery.singleLineText,
                prompt: Text(TermindCopy.Settings.filterByClientToolHostOrArgument), axis: .horizontal
            )
            .singleLinePaste()
            .lineLimit(1)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            let rows = app.toolAudit.entries(matching: historyQuery)
            if rows.isEmpty {
                ContentUnavailableView(
                    TermindCopy.Settings.noExternalCalls.swiftUIKey, systemImage: "clock.arrow.circlepath",
                    description: Text(TermindCopy.Settings.callsAppearHereAfterAnMcpClientInvokesATool)
                )
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                ForEach(rows.prefix(200)) { row in ExternalToolCallRow(row: row) }
            }
            HStack {
                Button(TermindCopy.Common.clearHistory.swiftUIKey, role: .destructive) { confirmsHistoryClear = true }
                Spacer()
                Text(TermindCopy.Settings.toolAuditStorageExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            TermindCopy.Settings.clearCallHistoryConfirmation.swiftUIKey, isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button(TermindCopy.Common.clearHistory.swiftUIKey, role: .destructive) { app.toolAudit.clear() }
            Button(TermindCopy.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(TermindCopy.Settings.thisPermanentlyRemovesAllSavedMcpCallRecords)
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
        return Section(TermindCopy.Settings.connectClients.swiftUIKey) {
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
                    CopyButton(text: command ?? "", title: TermindCopy.Settings.copyAddCommand)
                        .disabled(command == nil)
                        .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                if displayToken.isEmpty {
                    Text(TermindCopy.Settings.generateATokenToCopyClientSetupCommands)
                }
                if setup.bridgePath == nil {
                    Text(TermindCopy.Settings.missingMCPBridge)
                }
                Text(TermindCopy.Settings.mcpSetupExplanation)
                Text(TermindCopy.Settings.hermesSetupRequirement)
                Text(
                    TermindCopy.Settings.mcpClientConfigurationReminder
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
                        Text(duration, format: .number.precision(.fractionLength(2)))
                            + Text(TermindCopy.MCP.secondsSuffix)
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

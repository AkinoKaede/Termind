// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

struct MCPServerSettings: View {
    @Environment(AppModel.self) private var app
    @State private var showsToken = false
    @State private var historyQuery = ""
    @State private var confirmsHistoryClear = false

    private var server: MCPServerController { app.mcpServer }

    var body: some View {
        Section(AppStrings.Settings.builtInServer.swiftUIKey) {
            Toggle(
                AppStrings.Settings.enable.swiftUIKey,
                isOn: Binding(
                    get: { server.isEnabled },
                    set: { server.setEnabled($0) }
                ))

            LabeledContent(AppStrings.Common.status.swiftUIKey) {
                HStack(spacing: Metrics.Space.s) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(server.status.label).foregroundStyle(.secondary)
                }
            }
            LabeledContent(AppStrings.Common.port.swiftUIKey) {
                TextField(
                    AppStrings.Common.port.swiftUIKey,
                    value: Binding(
                        get: { server.port },
                        set: { server.setPort($0) }
                    ), format: .number.grouping(.never)
                ).lineLimit(1)
                    .labelsHidden()
                    .frame(width: 100)
                    .multilineTextAlignment(.trailing)
            }
            Text(
                AppStrings.Settings.mcpServerAccessExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(AppStrings.Settings.bearerToken.swiftUIKey) {
            HStack(alignment: .center) {
                Text(AppStrings.Settings.token)
                Spacer()
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
                            ? AppStrings.Settings.hideSecret.swiftUIKey : AppStrings.Settings.showSecret.swiftUIKey)
                    HStack(spacing: Metrics.Space.xxs) {
                        CopyButton(text: displayToken)
                            .disabled(displayToken.isEmpty)
                        if !displayToken.isEmpty {
                            Button {
                                server.rotateToken()
                                showsToken = true
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 28, height: 28)
                                    .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .help(Text(AppStrings.Settings.rotateToken))
                            .accessibilityLabel(Text(AppStrings.Settings.rotateToken))
                        }
                    }
                }
            }
            if !displayToken.isEmpty {
                Text(AppStrings.Settings.rotatingDisconnectsEveryActiveMcpSession)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = server.tokenStorageError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task {
            _ = server.ensureToken()
        }

        clientSetupSection

        Section(AppStrings.Settings.exposedTools.swiftUIKey) {
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
                AppStrings.Settings.mcpToolChangesExplanation
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(AppStrings.Settings.callHistory.swiftUIKey) {
            TextField(
                AppStrings.Settings.filterByClientToolHostOrArgument.swiftUIKey, text: $historyQuery.singleLineText,
                prompt: Text(AppStrings.Settings.filterByClientToolHostOrArgument), axis: .horizontal
            )
            .singleLinePaste()
            .lineLimit(1)
            .labelsHidden()
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            let rows = app.toolAudit.entries(matching: historyQuery)
            if rows.isEmpty {
                ContentUnavailableView(
                    AppStrings.Settings.noExternalCalls.swiftUIKey, systemImage: "clock.arrow.circlepath",
                    description: Text(AppStrings.Settings.callsAppearHereAfterAnMcpClientInvokesATool)
                )
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                ForEach(rows.prefix(200)) { row in ExternalToolCallRow(row: row) }
            }
            HStack {
                Button(AppStrings.Common.clearAll.swiftUIKey, role: .destructive) { confirmsHistoryClear = true }
                Spacer()
                Text(AppStrings.Settings.toolAuditStorageExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            AppStrings.Settings.clearCallHistoryConfirmation, isPresented: $confirmsHistoryClear,
            titleVisibility: .visible
        ) {
            Button(AppStrings.Common.clearAll.swiftUIKey, role: .destructive) { app.toolAudit.clear() }
            Button(AppStrings.Common.cancel.swiftUIKey, role: .cancel) {}
        } message: {
            Text(AppStrings.Settings.thisPermanentlyRemovesAllSavedMcpCallRecords)
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
        return Section(AppStrings.Settings.connectClients.swiftUIKey) {
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
                    CopyButton(text: command ?? "", title: AppStrings.Settings.copyAddCommand)
                        .disabled(command == nil)
                        .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                if setup.bridgePath == nil {
                    Text(AppStrings.Settings.missingMCPBridge)
                }
                Text(AppStrings.Settings.mcpSetupExplanation)
                Text(AppStrings.Settings.hermesSetupRequirement)
                Text(
                    AppStrings.Settings.mcpClientConfigurationReminder
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
                            + Text(AppStrings.MCP.secondsSuffix)
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

import SwiftUI

/// The "MCP" section: servers whose tools the assistant may call.
///
/// HTTP only, and that is a property of the app rather than a shortcut — Termind is
/// sandboxed, so it cannot launch the local process a stdio server would need.
/// The footnote says so, because "why is there no stdio option" is otherwise a
/// reasonable thing to wonder for a while.
struct MCPSettings: View {
    @Environment(AppModel.self) private var app
    let edit: (MCPServer.ID, Bool) -> Void

    var body: some View {
        Section {
            ForEach(app.aiConfiguration.mcpServers) { server in
                MCPServerRow(server: server) { edit(server.id, false) }
            }

            FormNavigationAction(title: "Add Server") {
                guard app.proAccess.require(.remoteMCP) else { return }
                let server = MCPServer(name: "", namespaceID: "")
                app.aiConfiguration.upsert(server)
                edit(server.id, true)
            }

            Text(
                "Termind connects directly from this Mac over HTTP. Tools ask for approval before running by default."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if let error = app.aiConfiguration.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("MCP")
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            StatusDot(status: app.aiConfiguration.mcpStatus(of: server.id))
                .frame(width: Metrics.Sidebar.rowIcon)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                if !server.namespaceID.isEmpty {
                    Text(server.namespaceID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(server.url.isEmpty ? String(localized: "No URL") : server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.m)

            CardChip(text: server.transport.displayName)

            if server.tools.isEmpty {
                CardChip(text: String(localized: "Not Connected"), symbol: "questionmark.circle")
            } else {
                CardChip(text: "\(server.enabledTools.count)/\(server.tools.count)", symbol: "wrench.and.screwdriver")
            }

            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text("Enable \(server.name)"))

            Button {
                guard app.proAccess.require(.remoteMCP) else { return }
                edit()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(server.name)"))
        }
        .contentShape(.rect)
        .onTapGesture {
            guard app.proAccess.require(.remoteMCP) else { return }
            edit()
        }
        .help(Text(app.aiConfiguration.mcpStatus(of: server.id).label))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: {
                guard app.proAccess.require(.remoteMCP) else { return }
                app.aiConfiguration.setServerEnabled($0, for: server.id)
            }
        )
    }
}

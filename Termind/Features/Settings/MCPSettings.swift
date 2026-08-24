import SwiftUI

/// The "MCP" section: servers whose tools the assistant may call.
///
/// HTTP only, and that is a property of the app rather than a shortcut — Termind is
/// sandboxed, so it cannot launch the local process a stdio server would need.
/// The footnote says so, because "why is there no stdio option" is otherwise a
/// reasonable thing to wonder for a while.
struct MCPSettings: View {
    @Environment(AppModel.self) private var app

    @State private var editing: EditingServer?

    var body: some View {
        Section {
            ForEach(app.ai.mcpServers) { server in
                MCPServerRow(server: server) { editing = EditingServer(id: server.id) }
            }

            Button("Add Server") {
                let server = MCPServer(name: String(localized: "New Server"))
                app.ai.upsert(server)
                editing = EditingServer(id: server.id, isNew: true)
            }

            Text(
                "Termind connects directly from this Mac over HTTP. Tools ask for approval before running by default."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("MCP")
        }
        .sheet(item: $editing) { editing in
            MCPServerEditorSheet(serverID: editing.id, isNew: editing.isNew)
        }
    }
}

private struct MCPServerRow: View {
    let server: MCPServer
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            StatusDot(status: app.ai.mcpStatus(of: server.id))
                .frame(width: Metrics.Sidebar.rowIcon)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .lineLimit(1)
                Text(server.url.isEmpty ? String(localized: "No URL") : server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.m)

            CardChip(text: server.transport.displayName)

            if server.tools.isEmpty {
                CardChip(text: String(localized: "Not connected"), symbol: "questionmark.circle")
            } else {
                CardChip(text: "\(server.enabledTools.count)/\(server.tools.count)", symbol: "wrench.and.screwdriver")
            }

            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text("Enable \(server.name)"))

            Button(action: edit) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Edit \(server.name)"))
        }
        .contentShape(.rect)
        .onTapGesture(perform: edit)
        .help(Text(app.ai.mcpStatus(of: server.id).label))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: { app.ai.setServerEnabled($0, for: server.id) }
        )
    }
}

/// What `.sheet(item:)` carries. See `EditingModelProvider` for why this is a
/// wrapper rather than a retroactive conformance on `UUID`.
private struct EditingServer: Identifiable {
    var id: MCPServer.ID
    /// True only when the row was made by Add Server, so Cancel knows the
    /// difference between undoing edits and undoing the row itself.
    var isNew = false
}

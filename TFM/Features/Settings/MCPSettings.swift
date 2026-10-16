import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation
import UniformTypeIdentifiers

/// The "MCP" section: servers whose tools the assistant may call.
///
/// HTTP only, and that is a property of the app rather than a shortcut — Termind is
/// sandboxed, so it cannot launch the local process a stdio server would need.
struct MCPSettings: View {
    @Environment(AppModel.self) private var app
    let edit: (MCPServer.ID, Bool) -> Void
    let openServer: () -> Void

    @State private var importReport: MCPImportReport?
    @State private var importProblem: MCPImportProblem?

    var body: some View {
        Section {
            if !app.aiConfiguration.conflictingMCPServerIDs.isEmpty {
                Label(
                    AppStrings.Settings.duplicateMCPNamespaces.swiftUIKey,
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            ForEach(app.aiConfiguration.mcpServers) { server in
                MCPServerRow(server: server) { edit(server.id, false) }
            }

            FormNavigationAction(title: AppStrings.MCP.addServer) {

                let server = MCPServer(name: "", namespaceID: "")
                app.aiConfiguration.upsert(server)
                edit(server.id, true)
            }

            Button(AppStrings.MCP.importServers.swiftUIKey) { importMCP() }
            if importReport != nil || importProblem != nil {
                MCPImportFeedback(report: importReport, problem: importProblem)
            }

            if let error = app.aiConfiguration.storageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(AppStrings.Settings.mcp)
        }

        Section {
            FormNavigationAction(title: AppStrings.Settings.builtInServer, action: openServer)
        }
    }

    private func importMCP() {

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        importReport = nil
        importProblem = nil
        do {
            importReport = app.aiConfiguration.importMCP(try MCPImporter.read(url))
        } catch {
            importProblem = error as? MCPImportProblem ?? .unreadableFile
        }
    }

}

private struct MCPServerRow: View {
    let server: MCPServer
    let edit: () -> Void

    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: Metrics.Space.m) {
            ConnectionStatusDot(status: app.aiConfiguration.mcpStatus(of: server.id))
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
                Text(server.url.isEmpty ? String(localized: AppStrings.Settings.noUrl) : server.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Metrics.Space.m)

            CardChip(text: server.transport.displayName)

            if server.tools.isEmpty {
                CardChip(text: String(localized: AppStrings.Settings.notConnected), symbol: "questionmark.circle")
            } else {
                CardChip(text: "\(server.tools.count)", symbol: "wrench")
            }

            Toggle("", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(Text(AppStrings.Settings.enableNamed(server.name)))

            Button {

                edit()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppStrings.Settings.edit(server.name)))
        }
        .contentShape(.rect)
        .onTapGesture {

            edit()
        }
        .help(Text(app.aiConfiguration.mcpStatus(of: server.id).label))
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { server.isEnabled },
            set: {

                app.aiConfiguration.setServerEnabled($0, for: server.id)
            }
        )
    }
}

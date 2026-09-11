import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure

struct MobileMCPSettings: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var editing: MCPServer?
    @State private var deleting: MCPServer?

    var body: some View {
        List {
            Section {
                if !ai.conflictingMCPServerIDs.isEmpty {
                    Text(
                        "Some MCP servers have duplicate namespaces and are paused. Edit their namespace IDs to resolve the conflict."
                    )
                    .foregroundStyle(.orange)
                }
                if ai.mcpServers.isEmpty {
                    ContentUnavailableView(
                        "No MCP Servers", systemImage: "network",
                        description: Text("Add an MCP server to connect remote tools.")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(ai.mcpServers) { server in
                    Button {
                        edit(server)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(.quaternary, in: .rect(cornerRadius: 7))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(server.name).foregroundStyle(.primary).lineLimit(1)
                                Text(server.url.isEmpty ? String(localized: "No URL") : server.url)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 8) {
                                MobileMCPStatusBadge(
                                    server: server,
                                    hasNamespaceConflict: ai.conflictingMCPServerIDs.contains(server.id))
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                        }.contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { edit(server) }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = server }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = server }
                    }
                }
            } footer: {
                Text("Connect to remote MCP servers over HTTP. New tools always ask for approval by default.")
            }
        }
        .navigationTitle("MCP")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Server", systemImage: "plus") {
                    if pro.require(.remoteMCP) { editing = MCPServer(name: "", namespaceID: "") }
                }
                .labelStyle(.iconOnly)
            }
        }
        .sheet(item: $editing) { MobileMCPEditor(ai: ai, pro: pro, server: $0) }
        .confirmationDialog(
            "Delete Server",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Server", role: .destructive) {
                if let deleting { ai.delete(serverID: deleting.id) }
                deleting = nil
            }
        }
    }

    private func edit(_ server: MCPServer) {
        if pro.require(.remoteMCP) { editing = server }
    }
}

private struct MobileMCPStatusBadge: View {
    let status: MobileMCPServerStatus

    init(server: MCPServer, hasNamespaceConflict: Bool) {
        status = MobileMCPServerStatus(server: server, hasNamespaceConflict: hasNamespaceConflict)
    }

    var body: some View {
        label
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: .capsule)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder private var label: some View {
        switch status {
        case .conflict:
            Text("Conflict")
        case .disabled:
            Text("Disabled")
        case .notConnected:
            Text("Not Connected")
        case .tools(let enabled, let total):
            Text("\(enabled)/\(total) tools")
        }
    }

    private var tint: Color {
        switch status {
        case .conflict: .orange
        case .disabled, .notConnected: .secondary
        case .tools: .accentColor
        }
    }
}

nonisolated enum MobileMCPServerStatus: Equatable {
    case conflict
    case disabled
    case notConnected
    case tools(enabled: Int, total: Int)

    init(server: MCPServer, hasNamespaceConflict: Bool) {
        if hasNamespaceConflict {
            self = .conflict
        } else if !server.isEnabled {
            self = .disabled
        } else if server.lastConnectedAt == nil {
            self = .notConnected
        } else {
            self = .tools(enabled: server.enabledTools.count, total: server.tools.count)
        }
    }
}

struct MobileMCPEditor: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var model: MobileMCPEditorModel
    @State private var deleting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    init(ai: AIConfigurationModel, pro: ProAccessController, server: MCPServer) {
        self.ai = ai
        self.pro = pro
        _model = State(initialValue: MobileMCPEditorModel(ai: ai, server: server))
    }

    var body: some View {
        MobileEditorSheet(
            title: String(localized: "MCP Server"), isDirty: model.isDirty,
            canSave: model.canSave && pro.canUse(.remoteMCP), actions: toolbarActions,
            save: { try model.save() },
            content: {
                Section("Connection") {
                    LabeledContent("Name") {
                        TextField("Name", text: $model.draft.name).multilineTextAlignment(.trailing)
                    }
                    Toggle("Enabled", isOn: $model.draft.isEnabled)
                    LabeledContent("ID") {
                        Text(model.draft.effectiveNamespaceID).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    if model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Name is required.").foregroundStyle(.orange)
                    } else if model.draft.effectiveNamespaceID.isEmpty {
                        Text("Name must produce an ID containing ASCII letters or numbers.").foregroundStyle(.orange)
                    } else if ai.hasMCPNamespaceConflict(model.draft.effectiveNamespaceID, excluding: model.draft.id) {
                        Text("Another MCP server already uses this ID.").foregroundStyle(.orange)
                    }
                    Picker("Transport", selection: $model.draft.transport) {
                        ForEach(MCPServer.Transport.allCases) { Text($0.displayName).tag($0) }
                    }
                    LabeledContent("URL") {
                        TextField("MCP endpoint URL", text: $model.draft.url)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }
                    if !model.draft.url.isEmpty && !model.hasValidURL {
                        Text("Enter an HTTP or HTTPS MCP URL.").font(.caption).foregroundStyle(.orange)
                    }
                    Text(model.draft.transport.detail).font(.caption).foregroundStyle(.secondary)
                    if model.running { ProgressView() }
                    if let connection = model.connection { Text(connection).font(.caption).textSelection(.enabled) }
                }
                MobileSecretFields(key: model.key, isToken: true)
                Section("Custom Headers") {
                    Text("Sent in the Authorization header. Custom headers below are stored as plain text.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach($model.draft.headers) { $header in
                        VStack {
                            LabeledContent("Name") {
                                TextField("Header name", text: $header.name).multilineTextAlignment(.trailing)
                            }
                            LabeledContent("Value") {
                                TextField("Header value", text: $header.value).multilineTextAlignment(.trailing)
                            }
                            Button("Remove header", systemImage: "minus.circle", role: .destructive) {
                                model.draft.headers.removeAll { $0.id == header.id }
                            }
                        }.textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Button("Add Header", systemImage: "plus") { model.draft.headers.append(MCPHeader()) }
                    Text("For secrets, use the bearer token field above.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Tools") {
                    if model.draft.tools.isEmpty { Text("Connect to see what this server offers.") }
                    ForEach($model.draft.tools) { $tool in
                        VStack(alignment: .leading) {
                            Text(qualified(tool)).font(.caption.monospaced()).textSelection(.enabled)
                            if !tool.summary.isEmpty {
                                Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Picker("Permission", selection: $tool.accessPolicy) {
                                Text("Disabled").tag(MCPTool.AccessPolicy.disabled)
                                Text("Always Ask").tag(MCPTool.AccessPolicy.alwaysAsk)
                                Text("Follow Permissions").tag(MCPTool.AccessPolicy.followPermissions)
                            }
                        }
                    }
                    Text(
                        "Always Ask requires approval for every call. Follow Permissions uses the conversation's permission mode and safety checks."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
        )
        .onChange(of: model.draft.name) { _, _ in model.cancel() }
        .onChange(of: model.draft.url) { _, _ in model.invalidateConnection() }
        .onChange(of: model.draft.transport) { _, _ in model.invalidateConnection() }
        .onChange(of: model.draft.headers) { _, _ in model.invalidateConnection() }
        .onChange(of: model.key.text) { _, _ in model.invalidateConnection() }
        .onChange(of: model.key.action) { _, _ in model.invalidateConnection() }
        .onChange(of: ai.mcpServer(model.original.id)) { _, _ in model.cancel() }
        .onChange(of: pro.hasProAccess) { _, granted in if !granted { model.cancel() } }
        .onDisappear { model.cancel() }
        .confirmationDialog("Delete Server?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                ai.delete(serverID: model.original.id)
                if let error = ai.storageError ?? ai.secretStorageError { self.error = error } else { dismiss() }
            }
        }
    }

    private var toolbarActions: [MobileEditorToolbarAction] {
        var actions = [
            MobileEditorToolbarAction(
                id: "connect", title: "Connect", systemImage: "bolt",
                isEnabled: model.canSave && !model.running,
                perform: { if pro.require(.remoteMCP) { model.connect() } })
        ]
        if ai.mcpServer(model.original.id) != nil {
            actions.append(
                MobileEditorToolbarAction(
                    id: "delete", title: "Delete", systemImage: "trash", role: .destructive,
                    startsGroup: true, perform: { deleting = true }))
        }
        return actions
    }

    private func qualified(_ tool: MCPTool) -> String {
        let leaf =
            MCPToolNaming.functionNames(for: model.draft.tools)[tool.id] ?? MCPToolNaming.functionName(from: tool.id)
        return MCPToolNaming.qualifiedName(namespace: model.draft.effectiveNamespaceID, function: leaf)
    }
}

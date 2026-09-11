import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure

struct MobileMCPSettings: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var adding: MCPServer?
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
                    serverLink(server)
                        .contextMenu {
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
                    if pro.require(.remoteMCP) { adding = MCPServer(name: "", namespaceID: "") }
                }
                .labelStyle(.iconOnly)
            }
        }
        .navigationDestination(item: $adding) { MobileMCPEditor(ai: ai, pro: pro, server: $0) }
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

    @ViewBuilder
    private func serverLink(_ server: MCPServer) -> some View {
        if pro.canUse(.remoteMCP) {
            NavigationLink {
                MobileMCPEditor(ai: ai, pro: pro, server: server)
            } label: {
                MobileMCPServerRow(
                    server: server,
                    hasNamespaceConflict: ai.conflictingMCPServerIDs.contains(server.id))
            }
        } else {
            Button {
                pro.require(.remoteMCP)
            } label: {
                HStack {
                    MobileMCPServerRow(
                        server: server,
                        hasNamespaceConflict: ai.conflictingMCPServerIDs.contains(server.id))
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct MobileMCPServerRow: View {
    let server: MCPServer
    let hasNamespaceConflict: Bool

    var body: some View {
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
            MobileMCPStatusBadge(server: server, hasNamespaceConflict: hasNamespaceConflict)
        }
        .contentShape(.rect)
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
    @State private var editingHeader: MCPHeader?
    @State private var deleting = false
    @State private var alert: EditorAlert?
    @Environment(\.dismiss) private var dismiss

    private struct EditorAlert {
        let title: LocalizedStringKey
        let message: String
    }

    init(ai: AIConfigurationModel, pro: ProAccessController, server: MCPServer) {
        self.ai = ai
        self.pro = pro
        _model = State(initialValue: MobileMCPEditorModel(ai: ai, server: server))
    }

    var body: some View {
        Form {
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
            Section {
                ForEach(model.draft.headers) { header in
                    NavigationLink {
                        MobileMCPHeaderEditor(header: header) { model.upsertHeader($0) }
                    } label: {
                        MobileMCPHeaderRow(header: header)
                    }
                    .contextMenu {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            removeHeader(header.id)
                        }
                    }
                }
                .onDelete(perform: model.removeHeaders)
                Button("Add Header", systemImage: "plus") { editingHeader = MCPHeader() }
            } header: {
                Text("Custom Headers")
            } footer: {
                Text("Custom headers are stored as plain text. For secrets, use the bearer token field above.")
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
        }
        .navigationTitle("MCP Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Connect", systemImage: "bolt") {
                        if pro.require(.remoteMCP) { model.connect() }
                    }
                    .disabled(!model.canSave || model.running)
                    if ai.mcpServer(model.original.id) != nil {
                        Divider()
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                    }
                } label: {
                    MobileOverflowMenuLabel("More")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text("Save"))
                .disabled(!model.canSave || !pro.canUse(.remoteMCP))
            }
        }
        .navigationDestination(item: $editingHeader) { header in
            MobileMCPHeaderEditor(header: header, focusesName: true) { model.upsertHeader($0) }
        }
        .onChange(of: model.draft.name) { _, _ in model.cancel() }
        .onChange(of: model.draft.url) { _, _ in model.invalidateConnection() }
        .onChange(of: model.draft.transport) { _, _ in model.invalidateConnection() }
        .onChange(of: model.key.text) { _, _ in model.invalidateConnection() }
        .onChange(of: model.key.action) { _, _ in model.invalidateConnection() }
        .onChange(of: ai.mcpServer(model.original.id)) { _, _ in model.cancel() }
        .onChange(of: pro.hasProAccess) { _, granted in if !granted { model.cancel() } }
        .onDisappear { model.cancel() }
        .confirmationDialog("Delete Server?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                ai.delete(serverID: model.original.id)
                if let error = ai.storageError ?? ai.secretStorageError {
                    alert = EditorAlert(title: "Unable to Delete", message: error)
                } else {
                    dismiss()
                }
            }
        }
        .alert(
            alert?.title ?? "Unable to Save",
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button("OK", role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func save() {
        do {
            try model.save()
            dismiss()
        } catch {
            alert = EditorAlert(title: "Unable to Save", message: error.localizedDescription)
        }
    }

    private func removeHeader(_ id: MCPHeader.ID) {
        guard let index = model.draft.headers.firstIndex(where: { $0.id == id }) else { return }
        model.removeHeaders(atOffsets: IndexSet(integer: index))
    }

    private func qualified(_ tool: MCPTool) -> String {
        let leaf =
            MCPToolNaming.functionNames(for: model.draft.tools)[tool.id] ?? MCPToolNaming.functionName(from: tool.id)
        return MCPToolNaming.qualifiedName(namespace: model.draft.effectiveNamespaceID, function: leaf)
    }
}

private struct MobileMCPHeaderRow: View {
    let header: MCPHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(header.isComplete ? header.name : String(localized: "Header name"))
                .foregroundStyle(header.isComplete ? .primary : .secondary)
                .lineLimit(1)
            if !header.value.isEmpty {
                Text(header.value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct MobileMCPHeaderEditor: View {
    let save: (MCPHeader) -> Void
    let focusesName: Bool
    @State private var draft: MCPHeader
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field {
        case name
        case value
    }

    init(header: MCPHeader, focusesName: Bool = false, save: @escaping (MCPHeader) -> Void) {
        self.save = save
        self.focusesName = focusesName
        _draft = State(initialValue: header)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("Header name", text: $draft.name)
                        .focused($focusedField, equals: .name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Value") {
                    TextField("Header value", text: $draft.value)
                        .focused($focusedField, equals: .value)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("Custom headers are stored as plain text. For secrets, use the bearer token field above.")
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle("Custom Header")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "checkmark") {
                    save(draft)
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .disabled(!draft.isComplete)
            }
        }
        .onAppear {
            if focusesName { focusedField = .name }
        }
    }
}

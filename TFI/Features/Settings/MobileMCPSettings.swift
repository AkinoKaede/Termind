import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation

struct MobileMCPSettings: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var adding: MCPServer?

    var body: some View {
        List {
            Section {
                if !ai.conflictingMCPServerIDs.isEmpty {
                    Text(
                        TermindCopy.Settings.duplicateMCPNamespaces
                    )
                    .foregroundStyle(.orange)
                }
                if ai.mcpServers.isEmpty {
                    ContentUnavailableView(
                        TermindCopy.Settings.noMcpServers.swiftUIKey, systemImage: "network",
                        description: Text(TermindCopy.Settings.addAnMcpServerToConnectRemoteTools)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(ai.mcpServers) { server in
                    serverLink(server)
                        .contextMenu {
                            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                ai.delete(serverID: server.id)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                ai.delete(serverID: server.id)
                            }
                        }
                }
            } footer: {
                Text(TermindCopy.Settings.connectToRemoteMcpServersOverHttp)
            }
        }
        .navigationTitle(TermindCopy.Settings.mcp.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(TermindCopy.MCP.addServer.swiftUIKey, systemImage: "plus") {
                    if pro.require(.remoteMCP) { adding = MCPServer(name: "", namespaceID: "") }
                }
                .labelStyle(.iconOnly)
            }
        }
        .navigationDestination(item: $adding) { MobileMCPEditor(ai: ai, pro: pro, server: $0) }
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
                Text(server.url.isEmpty ? String(localized: TermindCopy.Settings.noUrl) : server.url)
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
            Text(TermindCopy.Settings.conflict)
        case .disabled:
            Text(TermindCopy.Settings.disabled)
        case .notConnected:
            Text(TermindCopy.Settings.notConnected)
        case .tools(let count):
            Text(TermindCopy.Settings.toolsNamed(count))
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
    case tools(count: Int)

    init(server: MCPServer, hasNamespaceConflict: Bool) {
        if hasNamespaceConflict {
            self = .conflict
        } else if !server.isEnabled {
            self = .disabled
        } else if server.lastConnectedAt == nil {
            self = .notConnected
        } else {
            self = .tools(count: server.tools.count)
        }
    }
}

struct MobileMCPEditor: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var model: MobileMCPEditorModel
    @State private var editingHeader: MCPHeader?
    @State private var alert: EditorAlert?
    @Environment(\.dismiss) private var dismiss

    private struct EditorAlert {
        let title: LocalizedStringResource
        let message: String
    }

    init(ai: AIConfigurationModel, pro: ProAccessController, server: MCPServer) {
        self.ai = ai
        self.pro = pro
        _model = State(initialValue: MobileMCPEditorModel(ai: ai, server: server))
    }

    var body: some View {
        Form {
            Section(TermindCopy.Settings.connection.swiftUIKey) {
                LabeledContent(TermindCopy.Common.name.swiftUIKey) {
                    TextField(
                        TermindCopy.Common.name.swiftUIKey, text: $model.draft.name.singleLineText, axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(TermindCopy.Common.enabled.swiftUIKey, isOn: $model.draft.isEnabled)
                LabeledContent(TermindCopy.Settings.id.swiftUIKey) {
                    Text(model.draft.effectiveNamespaceID).font(.caption.monospaced()).textSelection(.enabled)
                }
                if model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(TermindCopy.Settings.nameIsRequired).foregroundStyle(.orange)
                } else if model.draft.effectiveNamespaceID.isEmpty {
                    Text(TermindCopy.Settings.namespaceNameRequirement).foregroundStyle(.orange)
                } else if ai.hasMCPNamespaceConflict(model.draft.effectiveNamespaceID, excluding: model.draft.id) {
                    Text(TermindCopy.Settings.anotherMcpServerAlreadyUsesThisId).foregroundStyle(.orange)
                }
                Picker(TermindCopy.Settings.transport.swiftUIKey, selection: $model.draft.transport) {
                    ForEach(MCPServer.Transport.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent(TermindCopy.Settings.url.swiftUIKey) {
                    TextField(
                        TermindCopy.Settings.mcpEndpointUrl.swiftUIKey, text: $model.draft.url.singleLineText,
                        axis: .horizontal
                    )
                    .singleLinePaste().lineLimit(1)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                }
                if !model.draft.url.isEmpty && !model.hasValidURL {
                    Text(TermindCopy.Settings.enterAnHttpOrHttpsMcpUrl).font(.caption).foregroundStyle(.orange)
                }
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
                        Button(TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            removeHeader(header.id)
                        }
                    }
                }
                .onDelete(perform: model.removeHeaders)
                Button(TermindCopy.Settings.addHeader.swiftUIKey, systemImage: "plus") { editingHeader = MCPHeader() }
            } header: {
                Text(TermindCopy.Settings.customHeaders)
            }
            Section(TermindCopy.Settings.tools.swiftUIKey) {
                if model.draft.tools.isEmpty { Text(TermindCopy.Settings.connectToSeeWhatThisServerOffers) }
                ForEach($model.draft.tools) { $tool in
                    VStack(alignment: .leading) {
                        Text(qualified(tool)).font(.caption.monospaced()).textSelection(.enabled)
                        if !tool.summary.isEmpty {
                            Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Picker(TermindCopy.Common.permission.swiftUIKey, selection: $tool.accessPolicy) {
                            Text(TermindCopy.Common.deny).tag(AgentToolDescriptor.ApprovalPolicy.deny)
                            Text(TermindCopy.Settings.ask).tag(AgentToolDescriptor.ApprovalPolicy.ask)
                            Text(TermindCopy.Settings.approve)
                                .tag(AgentToolDescriptor.ApprovalPolicy.approve)
                        }
                    }
                }
                Text(
                    TermindCopy.Settings.toolApprovalExplanation
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(TermindCopy.MCP.mcpServer.swiftUIKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MobileToolbarOverflow {
                Button(TermindCopy.Common.connect.swiftUIKey, systemImage: "bolt") {
                    if pro.require(.remoteMCP) { model.connect() }
                }
                .disabled(!model.canSave || model.running)
                if ai.mcpServer(model.original.id) != nil {
                    Divider()
                    Button(
                        TermindCopy.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive, action: delete)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Label(TermindCopy.Common.save.swiftUIKey, systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text(TermindCopy.Common.save))
                .disabled(!model.canSave || !pro.canUse(.remoteMCP))
            }
            .mobileProminentAction()
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
        .alert(
            (alert?.title ?? TermindCopy.Common.unableToSave).swiftUIKey,
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button(TermindCopy.Common.ok.swiftUIKey, role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private func delete() {
        ai.delete(serverID: model.original.id)
        if let error = ai.storageError ?? ai.secretStorageError {
            alert = EditorAlert(title: TermindCopy.Common.unableToDelete, message: error)
        } else {
            dismiss()
        }
    }

    private func save() {
        do {
            try model.save()
            dismiss()
        } catch {
            alert = EditorAlert(title: TermindCopy.Common.unableToSave, message: error.localizedDescription)
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
            Text(header.isComplete ? header.name : String(localized: TermindCopy.Settings.headerName))
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
                LabeledContent(TermindCopy.Common.name.swiftUIKey) {
                    TextField(
                        TermindCopy.Settings.headerName.swiftUIKey, text: $draft.name.singleLineText, axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .focused($focusedField, equals: .name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(TermindCopy.Common.value.swiftUIKey) {
                    TextField(
                        TermindCopy.Settings.headerValue.swiftUIKey, text: $draft.value.singleLineText,
                        axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .focused($focusedField, equals: .value)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(TermindCopy.Settings.headerStorageWarning)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(TermindCopy.Settings.customHeader.swiftUIKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(TermindCopy.Common.done.swiftUIKey, systemImage: "checkmark") {
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

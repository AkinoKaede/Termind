import AgentKit
import SwiftUI
import TermindApplication
import TermindInfrastructure
import TermindPresentation
import UniformTypeIdentifiers

struct MobileMCPSettings: View {
    let ai: AIConfigurationModel
    let pro: ProAccessController
    @State private var adding: MCPServer?
    @State private var importing = false
    @State private var importReport: MCPImportReport?
    @State private var importProblem: MCPImportProblem?

    var body: some View {
        List {
            Section {
                if !ai.conflictingMCPServerIDs.isEmpty {
                    Text(
                        AppStrings.Settings.duplicateMCPNamespaces
                    )
                    .foregroundStyle(.orange)
                }
                if ai.mcpServers.isEmpty {
                    ContentUnavailableView(
                        AppStrings.Settings.noMcpServers.swiftUIKey, systemImage: "network",
                        description: Text(AppStrings.Settings.addAnMcpServerToConnectRemoteTools)
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                ForEach(ai.mcpServers) { server in
                    serverLink(server)
                        .contextMenu {
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                ai.delete(serverID: server.id)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                                ai.delete(serverID: server.id)
                            }
                        }
                }
            } footer: {
                Text(AppStrings.Settings.connectToRemoteMcpServersOverHttp)
            }
            MCPImportFeedback(report: importReport, problem: importProblem)
        }
        .navigationTitle(AppStrings.Settings.mcp.swiftUIKey)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(AppStrings.MCP.addServer.swiftUIKey, systemImage: "plus") {
                    if pro.require(.remoteMCP) { adding = MCPServer(name: "", namespaceID: "") }
                }
                .labelStyle(.iconOnly)
            }
            MobileToolbarOverflow {
                Button(AppStrings.Common.import.swiftUIKey, systemImage: "square.and.arrow.down") {
                    if pro.require(.remoteMCP) { importing = true }
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .failure(let error) = result,
                (error as NSError).domain == NSCocoaErrorDomain,
                (error as NSError).code == CocoaError.userCancelled.rawValue
            {
                return
            }
            guard pro.require(.remoteMCP) else { return }
            importReport = nil
            importProblem = nil
            do {
                importReport = ai.importMCP(try MCPImporter.read(result.get()))
            } catch {
                importProblem = error as? MCPImportProblem ?? .unreadableFile
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
                Text(server.url.isEmpty ? String(localized: AppStrings.Settings.noUrl) : server.url)
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
            Text(AppStrings.Settings.conflict)
        case .disabled:
            Text(AppStrings.Settings.disabled)
        case .notConnected:
            Text(AppStrings.Settings.notConnected)
        case .tools(let count):
            Text(AppStrings.Settings.toolsNamed(count))
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
    @State private var browser = MCPWebAuthenticationPresenter()
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
            Section(AppStrings.Settings.connection.swiftUIKey) {
                LabeledContent(AppStrings.Common.name.swiftUIKey) {
                    TextField(
                        AppStrings.Common.name.swiftUIKey, text: $model.draft.name.singleLineText, axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .multilineTextAlignment(.trailing)
                }
                Toggle(AppStrings.Common.enabled.swiftUIKey, isOn: $model.draft.isEnabled)
                LabeledContent(AppStrings.Settings.id.swiftUIKey) {
                    Text(model.draft.effectiveNamespaceID).font(.caption.monospaced()).textSelection(.enabled)
                }
                if model.draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(AppStrings.Settings.nameIsRequired).foregroundStyle(.orange)
                } else if model.draft.effectiveNamespaceID.isEmpty {
                    Text(AppStrings.Settings.namespaceNameRequirement).foregroundStyle(.orange)
                } else if ai.hasMCPNamespaceConflict(model.draft.effectiveNamespaceID, excluding: model.draft.id) {
                    Text(AppStrings.Settings.anotherMcpServerAlreadyUsesThisId).foregroundStyle(.orange)
                }
                Picker(AppStrings.Settings.transport.swiftUIKey, selection: $model.draft.transport) {
                    ForEach(MCPServer.Transport.allCases) { Text($0.displayName).tag($0) }
                }
                LabeledContent(AppStrings.Settings.url.swiftUIKey) {
                    TextField(
                        AppStrings.Settings.mcpEndpointUrl.swiftUIKey, text: $model.draft.url.singleLineText,
                        axis: .horizontal
                    )
                    .singleLinePaste().lineLimit(1)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .multilineTextAlignment(.trailing)
                }
                if !model.draft.url.isEmpty && !model.hasValidURL {
                    Text(AppStrings.Settings.enterAnHttpOrHttpsMcpUrl).font(.caption).foregroundStyle(.orange)
                }
                if model.running { ProgressView() }
                if let connection = model.connection { Text(connection).font(.caption).textSelection(.enabled) }
            }
            MobileSecretFields(key: model.key, isToken: true)
            oauthSection
            Section {
                ForEach(model.draft.headers) { header in
                    NavigationLink {
                        MobileMCPHeaderEditor(header: header) { model.upsertHeader($0) }
                    } label: {
                        MobileMCPHeaderRow(header: header)
                    }
                    .contextMenu {
                        Button(AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive) {
                            removeHeader(header.id)
                        }
                    }
                }
                .onDelete(perform: model.removeHeaders)
                Button(AppStrings.Settings.addHeader.swiftUIKey, systemImage: "plus") { editingHeader = MCPHeader() }
            } header: {
                Text(AppStrings.Settings.customHeaders)
            }
            Section(AppStrings.Settings.tools.swiftUIKey) {
                if model.draft.tools.isEmpty { Text(AppStrings.Settings.connectToSeeWhatThisServerOffers) }
                ForEach($model.draft.tools) { $tool in
                    VStack(alignment: .leading) {
                        Text(qualified(tool)).font(.caption.monospaced()).textSelection(.enabled)
                        if !tool.summary.isEmpty {
                            Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Picker(AppStrings.Common.permission.swiftUIKey, selection: $tool.accessPolicy) {
                            Text(AppStrings.Common.deny).tag(AgentToolDescriptor.ApprovalPolicy.deny)
                            Text(AppStrings.Settings.ask).tag(AgentToolDescriptor.ApprovalPolicy.ask)
                            Text(AppStrings.Settings.approve)
                                .tag(AgentToolDescriptor.ApprovalPolicy.approve)
                        }
                    }
                }
                Text(
                    AppStrings.Settings.toolApprovalExplanation
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(AppStrings.MCP.mcpServer.swiftUIKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            MobileToolbarOverflow {
                Button(AppStrings.Common.connect.swiftUIKey, systemImage: "bolt") {
                    if pro.require(.remoteMCP) { model.connect(interaction: browser.interaction) }
                }
                .disabled(!model.canSave || model.running)
                if ai.mcpServer(model.original.id) != nil {
                    Divider()
                    Button(
                        AppStrings.Common.delete.swiftUIKey, systemImage: "trash", role: .destructive, action: delete)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    save()
                } label: {
                    Label(AppStrings.Common.save.swiftUIKey, systemImage: "checkmark")
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel(Text(AppStrings.Common.save))
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
        .background(MCPAuthorizationAnchor(presenter: browser).frame(width: 0, height: 0))
        .onChange(of: model.draft.oauth) { _, _ in
            model.invalidateConnection()
            browser.cancel()
        }
        .onDisappear {
            model.cancel()
            browser.cancel()
        }
        .alert(
            alert?.title ?? AppStrings.Common.unableToSave,
            isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })
        ) {
            Button(AppStrings.Common.ok.swiftUIKey, role: .cancel) { alert = nil }
        } message: {
            Text(alert?.message ?? "")
        }
    }

    private var oauthSection: some View {
        Section {
            Label(
                (model.oauthSignedIn ? AppStrings.MCP.oauthSignedIn : AppStrings.MCP.oauthSignedOut).swiftUIKey,
                systemImage: model.oauthSignedIn ? "checkmark.circle" : "person.crop.circle")
            Button((model.oauthSignedIn ? AppStrings.MCP.oauthReauthorize : AppStrings.MCP.oauthSignIn).swiftUIKey) {
                guard pro.require(.remoteMCP) else { return }
                model.reauthorize(interaction: browser.interaction)
            }
            .disabled(
                !model.canSave || model.running || model.hasManualAuthorization)
            if model.oauthSignedIn {
                Button(AppStrings.MCP.oauthSignOut.swiftUIKey) {
                    browser.cancel()
                    Task { await model.signOut() }
                }
            }
            DisclosureGroup(AppStrings.MCP.oauthAdvanced.swiftUIKey) {
                TextField(
                    AppStrings.MCP.oauthIssuer.swiftUIKey, text: oauthBinding(\.issuer),
                    prompt: Text(AppStrings.MCP.oauthAutomatic)
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                TextField(
                    AppStrings.MCP.oauthClientID.swiftUIKey, text: oauthBinding(\.clientID),
                    prompt: Text(AppStrings.Common.optional)
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                RevealableSecretField(
                    AppStrings.MCP.oauthClientSecret, text: $model.oauthClientSecret,
                    prompt: Text(AppStrings.Common.optional))
            }
        } header: {
            Text(AppStrings.MCP.oauth)
        } footer: {
            Text(AppStrings.MCP.oauthDeviceOnly)
        }
    }

    private func oauthBinding(_ path: WritableKeyPath<MCPOAuthConfiguration, String>) -> Binding<String> {
        Binding(
            get: { model.draft.oauth?[keyPath: path] ?? "" },
            set: { value in
                var config = model.draft.oauth ?? .init()
                config[keyPath: path] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                model.draft.oauth = config.issuer.isEmpty && config.clientID.isEmpty ? nil : config
            })
    }

    private func delete() {
        ai.delete(serverID: model.original.id)
        if let error = ai.storageError ?? ai.secretStorageError {
            alert = EditorAlert(title: AppStrings.Common.unableToDelete, message: error)
        } else {
            dismiss()
        }
    }

    private func save() {
        do {
            try model.save()
            dismiss()
        } catch {
            alert = EditorAlert(title: AppStrings.Common.unableToSave, message: error.localizedDescription)
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
            Text(header.isComplete ? header.name : String(localized: AppStrings.Settings.headerName))
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
                LabeledContent(AppStrings.Common.name.swiftUIKey) {
                    TextField(
                        AppStrings.Settings.headerName.swiftUIKey, text: $draft.name.singleLineText, axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .focused($focusedField, equals: .name)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent(AppStrings.Common.value.swiftUIKey) {
                    TextField(
                        AppStrings.Settings.headerValue.swiftUIKey, text: $draft.value.singleLineText,
                        axis: .horizontal
                    ).singleLinePaste()
                        .lineLimit(1)
                        .focused($focusedField, equals: .value)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(AppStrings.Settings.headerStorageWarning)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .navigationTitle(AppStrings.Settings.customHeader.swiftUIKey)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppStrings.Common.done.swiftUIKey, systemImage: "checkmark") {
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

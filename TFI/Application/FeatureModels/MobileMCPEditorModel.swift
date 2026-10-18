import AgentKit
import Foundation
import Observation
import TermindApplication
import TermindPresentation

@MainActor @Observable
final class MobileMCPEditorModel {
    typealias Discover = @Sendable (MCPServer, String?) async throws -> MCPDiscovery
    let original: MCPServer
    var draft: MCPServer
    let key = MobileSecretDraft()
    private(set) var running = false
    private(set) var connection: String?
    private let ai: AIConfigurationModel
    private let wasPersisted: Bool
    private let discover: Discover?
    private let oauthDraft: MCPAuthorizationDraft?
    private var oauthLoadError: String?
    var oauthClientSecret: String {
        get { oauthDraft?.secret ?? "" }
        set {
            oauthDraft?.secret = newValue
            invalidateConnection()
        }
    }
    var oauthSignedIn: Bool { oauthDraft?.isSignedIn ?? false }
    var hasManualAuthorization: Bool {
        (key.action != .clear && (!draft.credentialRef.isEmpty || !key.text.isEmpty))
            || draft.headers.contains { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "authorization" }
    }
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var policies: [String: AgentToolDescriptor.ApprovalPolicy] = [:]

    init(
        ai: AIConfigurationModel, server: MCPServer,
        discover: Discover? = nil
    ) {
        self.ai = ai
        original = server
        draft = server
        wasPersisted = ai.mcpServer(server.id) != nil
        self.discover = discover
        do { oauthDraft = try ai.mcpAuthorization.draft(for: server) } catch {
            oauthDraft = nil
            oauthLoadError = error.localizedDescription
            connection = error.localizedDescription
        }
        key.begin(in: ai, reference: server.credentialRef)
    }
    var hasValidURL: Bool {
        guard let url = URL(string: draft.url.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty
        else { return false }
        return scheme == "https" || scheme == "http"
    }
    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.effectiveNamespaceID.isEmpty
            && !ai.hasMCPNamespaceConflict(draft.effectiveNamespaceID, excluding: draft.id)
            && hasValidURL && key.isValid && oauthLoadError == nil
    }
    func connect(interaction: MCPAuthorizationInteraction? = nil) {
        cancel()
        guard canSave, !wasPersisted || ai.mcpServer(original.id) != nil else { return }
        let secret: String
        do {
            secret = try key.effective(
                in: ai, reference: ai.mcpServer(original.id)?.credentialRef ?? draft.credentialRef)
        } catch {
            connection = error.localizedDescription
            return
        }
        for tool in original.tools + draft.tools { policies[tool.id] = tool.accessPolicy }
        var server = draft
        if key.action == .clear { server.credentialRef = "" }
        oauthDraft?.update(server)
        let persisted = ai.mcpServer(original.id)
        let keyAction = key.action
        let keyText = key.text
        let token = generation
        running = true
        task = Task { [weak self, discover] in
            defer { if self?.generation == token { self?.running = false } }
            do {
                let outcome: MCPDiscovery
                if let discover {
                    outcome = try await discover(server, secret.isEmpty ? nil : secret)
                } else {
                    guard let self, let oauthDraft else { throw CancellationError() }
                    outcome = try await MCPClient(
                        clientInfo: .init(
                            name: "Termind",
                            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"),
                        authorization: oauthDraft
                    ).discover(server, bearerToken: secret.isEmpty ? nil : secret, interaction: interaction)
                }
                guard let self, generation == token, !Task.isCancelled,
                    ai.mcpServer(original.id) == persisted, draft.name == server.name,
                    draft.url == server.url, draft.transport == server.transport, draft.headers == server.headers,
                    draft.oauth == server.oauth,
                    key.action == keyAction, key.text == keyText
                else { return }
                for tool in draft.tools { policies[tool.id] = tool.accessPolicy }
                var seen = Set<String>()
                draft.tools = outcome.tools.filter { seen.insert($0.id).inserted }.map {
                    var tool = $0
                    tool.accessPolicy = policies[tool.id] ?? tool.termindDefaultApprovalPolicy
                    return tool
                }
                draft.negotiatedVersion = outcome.protocolVersion
                draft.serverDescription = outcome.serverDescription
                draft.lastConnectedAt = .now
                connection = String(
                    localized: AppStrings.Settings.discoveredTools(
                        server: outcome.serverName, count: draft.tools.count))
            } catch {
                guard let self, generation == token, !Task.isCancelled,
                    ai.mcpServer(original.id) == persisted, draft.name == server.name,
                    draft.url == server.url, draft.transport == server.transport, draft.headers == server.headers,
                    draft.oauth == server.oauth,
                    key.action == keyAction, key.text == keyText
                else { return }
                connection = error is CancellationError ? nil : error.localizedDescription
            }
        }
    }
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        running = false
        connection = nil
    }
    func invalidateConnection() {
        cancel()
        oauthDraft?.update(draft)
        for tool in draft.tools { policies[tool.id] = tool.accessPolicy }
        draft.tools = []
        draft.negotiatedVersion = ""
        draft.serverDescription = nil
        draft.lastConnectedAt = nil
    }

    func signOut() async {
        cancel()
        if MCPAuthorizationGrantStore.sameBinding(original, draft), wasPersisted {
            await ai.mcpAuthorization.signOut(original)
            oauthDraft?.resetAfterSignOut()
        } else {
            try? await oauthDraft?.coordinator.signOut(serverID: draft.id)
        }
        connection = nil
    }

    func reauthorize(interaction: MCPAuthorizationInteraction) {
        cancel()
        oauthDraft?.requireAuthorization()
        connect(interaction: interaction)
    }

    deinit {
        let draft = oauthDraft
        Task { @MainActor in draft?.discard() }
    }

    func upsertHeader(_ header: MCPHeader) {
        if let index = draft.headers.firstIndex(where: { $0.id == header.id }) {
            guard draft.headers[index] != header else { return }
            draft.headers[index] = header
        } else {
            draft.headers.append(header)
        }
        invalidateConnection()
    }

    func removeHeaders(atOffsets offsets: IndexSet) {
        guard !offsets.isEmpty else { return }
        for index in offsets.sorted(by: >) { draft.headers.remove(at: index) }
        invalidateConnection()
    }

    func save() throws {
        guard canSave else { return }
        var value = draft
        if wasPersisted {
            guard let current = ai.mcpServer(original.id) else {
                throw MobileEditorError.message(String(localized: AppStrings.Settings.serverDeleted))
            }
            var fields = SettingsFields(original, draft, current)
            try fields.merge(\.name)
            try fields.merge(\.transport)
            try fields.merge(\.url)
            try fields.merge(\.isEnabled)
            try fields.merge(\.oauth)
            value = fields.result
            value.headers = try SettingsDraftMerge.collection(original.headers, draft.headers, current.headers) {
                old, local, remote in
                var fields = SettingsFields(old, local, remote)
                try fields.merge(\.name)
                try fields.merge(\.value)
                return fields.result
            }
            value.tools = try SettingsDraftMerge.collection(original.tools, draft.tools, current.tools) {
                old, local, remote in
                var fields = SettingsFields(old, local, remote)
                try fields.merge(\.accessPolicy)
                try fields.merge(\.title)
                try fields.merge(\.summary)
                try fields.merge(\.inputSchema)
                try fields.merge(\.annotations)
                return fields.result
            }
            if draft.lastConnectedAt != original.lastConnectedAt {
                value.lastConnectedAt = draft.lastConnectedAt
                value.negotiatedVersion = draft.negotiatedVersion
                value.serverDescription = draft.serverDescription
            }
        }
        value.url = value.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.namespaceID.isEmpty { value.namespaceID = value.effectiveNamespaceID }
        guard !ai.hasMCPNamespaceConflict(value.effectiveNamespaceID, excluding: value.id) else {
            throw MobileEditorError.message(String(localized: AppStrings.Settings.anotherMcpServerAlreadyUsesThisId))
        }
        guard let oauthDraft else { throw CancellationError() }
        try oauthDraft.commit(server: value) {
            try key.commit(in: ai, reference: value.credentialRef, kind: "mcp") { reference in
                value.credentialRef = reference
                ai.upsert(value)
                return ai.storageError == nil
            }
        }
    }
}

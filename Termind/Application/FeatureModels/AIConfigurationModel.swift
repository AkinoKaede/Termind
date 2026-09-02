import AgentKit
import Foundation

/// The single source of truth for model providers, their models, which model does
/// what, and the MCP servers.
///
/// Its own store rather than more fields on `HostLibraryModel`: that one is about
/// machines you connect to, this one is about endpoints you spend a key at.
/// Provider and MCP configuration are projected from SwiftData in production
/// while previews can still construct an in-memory store.
@Observable
final class AIConfigurationModel {
    private(set) var modelProviders: [ModelProvider] = []
    private(set) var mcpServers: [MCPServer] = []

    /// Explicit role assignments. Absent means "work it out" — see `resolve`.
    private(set) var roles: [AIRole: AIModelRef] = [:]

    /// The last model picked in a conversation's model menu.
    ///
    /// This is what makes the app usable with no configuration at all: choosing
    /// a model once, in the place you were already looking, quietly becomes the
    /// default for every conversation that has not chosen. It sits below an
    /// explicit Chat assignment and above first-available in `resolve`, so it
    /// never overrides a decision the user made in Settings.
    private(set) var lastSelectedModel: AIModelRef?

    /// The approval posture new and otherwise-unset conversations follow.
    /// Stored in local preferences rather than provider configuration so it
    /// survives relaunches without becoming part of the synced SwiftData model.
    private(set) var lastSelectedPermissionMode: AgentPermissionMode

    /// Live MCP connection state, keyed by server.
    ///
    /// Here rather than on `MCPServer` for the same reason `HostLibraryModel.statuses`
    /// is not on `Host`: it is session state, not user data, and it must never
    /// be persisted or synced.
    private(set) var mcpStatuses: [MCPServer.ID: ConnectionStatus] = [:]

    /// Session cache for API keys and service-account JSON. Production reads
    /// through to the Data Protection Keychain; previews keep their fake secret
    /// in memory so demo data never creates a real Keychain item.
    private var secrets: [String: String] = [:]
    private let keychain: any SecretStoring
    private let persistsSecrets: Bool
    private let permissionDefaults: UserDefaults?
    private(set) var secretStorageError: String?
    private var persistence: (any AIConfigurationPersisting)?
    private(set) var storageError: String?

    init(
        modelProviders: [ModelProvider] = [],
        mcpServers: [MCPServer] = [],
        roles: [AIRole: AIModelRef] = [:],
        lastSelectedModel: AIModelRef? = nil,
        lastSelectedPermissionMode: AgentPermissionMode = .askForApproval,
        persistence: (any AIConfigurationPersisting)? = nil,
        secrets secretStore: any SecretStoring = InMemorySecretStore(),
        persistsSecrets: Bool = true,
        permissionDefaults: UserDefaults? = nil
    ) {
        self.modelProviders = modelProviders
        self.mcpServers = mcpServers
        self.roles = roles
        self.lastSelectedModel = lastSelectedModel
        self.lastSelectedPermissionMode = permissionDefaults
            .flatMap { $0.string(forKey: SettingsKey.agentPermissionMode) }
            .flatMap(AgentPermissionMode.init(rawValue:))
            ?? lastSelectedPermissionMode
        self.persistence = persistence
        self.keychain = secretStore
        self.persistsSecrets = persistsSecrets
        self.permissionDefaults = permissionDefaults
        guard let persistence else { return }
        do {
            let loaded = try persistence.load()
            self.modelProviders = loaded.providers
            self.roles = loaded.roles
            self.lastSelectedModel = loaded.lastSelectedModel
            self.mcpServers = loaded.mcpServers
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Reads

    func modelProvider(_ id: ModelProvider.ID) -> ModelProvider? {
        modelProviders.first { $0.id == id }
    }

    /// Providers whose models may be offered anywhere. A provider with no
    /// credential is included: it may have hand-added models, and hiding it
    /// would make "why is my model missing" unanswerable from the picker.
    var enabledModelProviders: [ModelProvider] {
        modelProviders.filter(\.isEnabled)
    }

    /// Resolves a ref to the pair it names, or `nil` if either half has since
    /// been deleted, renamed, or disabled.
    ///
    /// Every step of `resolve` runs through here, which is what stops a stale
    /// assignment from silently pointing at nothing.
    func lookup(_ ref: AIModelRef) -> (provider: ModelProvider, model: AIModel)? {
        guard
            let provider = modelProvider(ref.modelProviderID),
            provider.isEnabled,
            let model = provider.model(ref.modelID)
        else { return nil }
        return (provider, model)
    }

    /// The fallback of last resort: the first chat model of the first enabled
    /// provider, in the order the lists are shown.
    var firstAvailableModel: AIModelRef? {
        for provider in enabledModelProviders {
            if let model = provider.chatModels.first {
                return AIModelRef(modelProviderID: provider.id, modelID: model.id)
            }
        }
        return nil
    }

    /// Which model answers a given job.
    ///
    /// One chain, and no step of it is required:
    ///
    ///   1. an explicit assignment for this role
    ///   2. for non-chat roles, whatever Chat resolves to
    ///   3. the last model picked in a conversation's menu
    ///   4. the first chat model of the first enabled provider
    ///
    /// Any step whose ref no longer resolves is skipped rather than returning
    /// nothing, so deleting a provider degrades the app instead of breaking it.
    /// The practical effect: add one provider, press Fetch, and the assistant
    /// works — the role pickers are for tuning, not for setup.
    func resolve(_ role: AIRole) -> (provider: ModelProvider, model: AIModel)? {
        if let ref = roles[role], let hit = lookup(ref) { return hit }
        if role != .chat, let ref = roles[.chat], let hit = lookup(ref) { return hit }
        if let ref = lastSelectedModel, let hit = lookup(ref) { return hit }
        if let ref = firstAvailableModel, let hit = lookup(ref) { return hit }
        return nil
    }

    /// The model a conversation will actually use.
    ///
    /// Its own choice if it made one, and whatever `.chat` resolves to if it did
    /// not. A conversation is left unset rather than assigned a model on
    /// creation, so this is the only place that difference has to be understood
    /// — the Assistant sidebar's model menu, the composer's caption, and the status bar
    /// all ask here instead of each reimplementing the fallback slightly
    /// differently.
    func resolve(conversation model: AIModelRef?) -> (provider: ModelProvider, model: AIModel)? {
        if let model, let hit = lookup(model) { return hit }
        return resolve(.chat)
    }

    /// An explicit conversation choice wins; otherwise the app-wide latest
    /// choice is the default. The latter begins at the safest posture.
    func resolve(conversation permissionMode: AgentPermissionMode?) -> AgentPermissionMode {
        permissionMode ?? lastSelectedPermissionMode
    }

    /// Whether a role is showing an explicit choice or following the chain.
    /// The picker needs this to know when to show its unset tag.
    func assignment(for role: AIRole) -> AIModelRef? {
        guard let ref = roles[role], lookup(ref) != nil else { return nil }
        return ref
    }

    /// Which roles would lose their explicit model if a provider were deleted.
    ///
    /// The counterpart of `HostLibraryModel.identities(using:)`, and used for the same
    /// reason: a delete button should say what it takes with it.
    func roles(using modelProviderID: ModelProvider.ID) -> [AIRole] {
        AIRole.allCases.filter { roles[$0]?.modelProviderID == modelProviderID }
    }

    func mcpServer(_ id: MCPServer.ID) -> MCPServer? {
        mcpServers.first { $0.id == id }
    }

    func mcpStatus(of id: MCPServer.ID) -> ConnectionStatus {
        mcpStatuses[id] ?? .disconnected
    }

    func hasMCPNamespaceConflict(_ namespaceID: String, excluding id: MCPServer.ID) -> Bool {
        !namespaceID.isEmpty && mcpServers.contains {
            $0.id != id && $0.effectiveNamespaceID == namespaceID
        }
    }

    /// Every tool the model may be offered: enabled tools on enabled servers.
    var availableTools: [(server: MCPServer, tool: MCPTool)] {
        mcpServers.filter(\.isEnabled).flatMap { server in
            server.enabledTools.map { (server, $0) }
        }
    }

    // MARK: - Secrets

    /// The secret behind a `credentialRef`, loaded from the Termind Data
    /// Protection Keychain and cached only for this process.
    func secret(for ref: String) -> String? {
        guard !ref.isEmpty else { return nil }
        if let cached = secrets[ref] { return cached }
        guard persistsSecrets else { return nil }
        do {
            let value = try keychain.string(for: ref, storage: .thisDevice)
            if let value { secrets[ref] = value }
            secretStorageError = nil
            return value
        } catch {
            secretStorageError = error.localizedDescription
            return nil
        }
    }

    /// Stores or clears a secret. `nil` forgets it, which is what emptying the
    /// field in an editor has to mean.
    func setSecret(_ secret: String?, for ref: String) {
        guard !ref.isEmpty else { return }
        do {
            if persistsSecrets {
                try keychain.setString(secret, for: ref, storage: .thisDevice)
            }
            secrets[ref] = secret
            secretStorageError = nil
        } catch {
            secretStorageError = error.localizedDescription
        }
    }

    /// Mints a reference for a new secret. The plaintext is handed over
    /// separately so the two are never in one value — the trick
    /// `NewIdentitySheet` already uses for passwords.
    static func makeCredentialRef(_ kind: String = "key") -> String {
        "termind.ai.\(kind).\(UUID().uuidString)"
    }

    // MARK: - Model provider writes

    func upsert(_ provider: ModelProvider) {
        mutatePersistedState {
            if let index = modelProviders.firstIndex(where: { $0.id == provider.id }) {
                modelProviders[index] = provider
            } else {
                modelProviders.append(provider)
            }
        }
    }

    /// Removes a provider along with everything that only made sense while it
    /// existed: its secrets, the role assignments pointing at it, and the
    /// remembered selection if that was one of its models.
    ///
    /// The same discipline as `HostLibraryModel.delete(identityID:)`. Leaving any of
    /// these behind would give `resolve` a ref that looks valid and is not, and
    /// the failure would surface at send time rather than here.
    func delete(modelProviderID: ModelProvider.ID) {
        guard let provider = modelProvider(modelProviderID) else { return }

        let deleted = mutatePersistedState {
            for role in roles(using: modelProviderID) {
                roles[role] = nil
            }
            if lastSelectedModel?.modelProviderID == modelProviderID {
                lastSelectedModel = nil
            }
            modelProviders.removeAll { $0.id == modelProviderID }
        }
        guard deleted else { return }
        setSecret(nil, for: provider.credentialRef)
        setSecret(nil, for: provider.vertex.credentialRef)
    }

    func setModelProviderEnabled(_ enabled: Bool, for id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            modelProviders[index].isEnabled = enabled
        }
    }

    // MARK: - Model writes

    /// Replaces the whole model list.
    ///
    /// Hand-added models are kept and merged rather than wiped: someone who
    /// typed a model the endpoint does not advertise — a private deployment, a
    /// preview id — should not lose it. A fetched row wins on conflict, since
    /// the server is better informed than a guess.
    ///
    /// Not what the Fetch button calls. A fetch offers a list and the user picks
    /// from it (see `ModelListEditor`), so the additions arrive one at a time
    /// through `addModel`. This exists for a caller that really does mean "this
    /// is now the list".
    func replaceModels(_ fetched: [AIModel], for id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            let previous = Dictionary(
                uniqueKeysWithValues: modelProviders[index].models.map { ($0.id, $0) }
            )
            let fetchedIDs = Set(fetched.map(\.id))
            let merged = fetched.map { fresh in
                var fresh = fresh
                fresh.reasoningProfile = previous[fresh.id]?.reasoningProfile
                fresh.isShownInAssistant =
                    previous[fresh.id]?.isShownInAssistant ?? fresh.isShownInAssistant
                return fresh
            }
            let kept = modelProviders[index].models.filter {
                $0.origin == .manual && !fetchedIDs.contains($0.id)
            }
            modelProviders[index].models = merged + kept
            modelProviders[index].modelsFetchedAt = Date()
        }
    }

    /// Records that the endpoint was asked, whatever the user then chose to add.
    ///
    /// Separate from adding, because "when did I last check what this endpoint
    /// offers" is a different question from "what did I keep", and the answer to
    /// the first is useful even when the answer to the second is "nothing".
    func markModelsFetched(for id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            modelProviders[index].modelsFetchedAt = Date()
        }
    }

    func addModel(_ model: AIModel, to id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            guard !modelProviders[index].models.contains(where: { $0.id == model.id }) else { return }
            modelProviders[index].models.append(model)
        }
    }

    func updateModel(_ model: AIModel, in id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            guard let slot = modelProviders[index].models.firstIndex(where: { $0.id == model.id }) else { return }
            modelProviders[index].models[slot] = model
        }
    }

    /// Removes models, and unhooks anything that pointed at them.
    ///
    /// Same reasoning as `delete(modelProviderID:)`: a role holding a ref to a model
    /// that no longer exists is a failure deferred to send time.
    func removeModels(_ ids: Set<String>, from modelProviderID: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == modelProviderID }) else { return }
            modelProviders[index].models.removeAll { ids.contains($0.id) }

            for role in AIRole.allCases {
                guard let ref = roles[role], ref.modelProviderID == modelProviderID, ids.contains(ref.modelID) else {
                    continue
                }
                roles[role] = nil
            }
            if let ref = lastSelectedModel, ref.modelProviderID == modelProviderID, ids.contains(ref.modelID) {
                lastSelectedModel = nil
            }
        }
    }

    // MARK: - Role writes

    func assign(_ ref: AIModelRef?, to role: AIRole) {
        mutatePersistedState { roles[role] = ref }
    }

    /// Records a choice made in a conversation's model menu.
    ///
    /// Not an assignment: it feeds step 3 of `resolve`, so it changes the
    /// default without overwriting anything the user set in Settings.
    func select(_ ref: AIModelRef) {
        mutatePersistedState { lastSelectedModel = ref }
    }

    /// Records a composer permission choice for subsequent unset conversations
    /// and future app launches. It does not alter command or MCP execution policy.
    func select(_ permissionMode: AgentPermissionMode) {
        lastSelectedPermissionMode = permissionMode
        permissionDefaults?.set(permissionMode.rawValue, forKey: SettingsKey.agentPermissionMode)
    }

    // MARK: - Provider persistence

    @discardableResult
    private func mutatePersistedState(_ mutation: () -> Void) -> Bool {
        let previous = persistedSnapshot
        mutation()
        guard let persistence else { return true }
        do {
            try persistence.save(persistedSnapshot)
            storageError = nil
            return true
        } catch {
            modelProviders = previous.providers
            roles = previous.roles
            lastSelectedModel = previous.lastSelectedModel
            mcpServers = previous.mcpServers
            storageError = error.localizedDescription
            return false
        }
    }

    private var persistedSnapshot: AIConfigurationSnapshot {
        AIConfigurationSnapshot(
            providers: modelProviders,
            roles: roles,
            lastSelectedModel: lastSelectedModel,
            mcpServers: mcpServers
        )
    }

    // MARK: - MCP writes

    func upsert(_ server: MCPServer) {
        mutatePersistedState {
            if let index = mcpServers.firstIndex(where: { $0.id == server.id }) {
                mcpServers[index] = server
            } else {
                mcpServers.append(server)
            }
        }
    }

    /// Locks a valid, unique draft namespace without changing the UUID identity.
    @discardableResult
    func lockMCPNamespace(for id: MCPServer.ID) -> Bool {
        guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return false }
        if !mcpServers[index].namespaceID.isEmpty { return true }
        let namespaceID = mcpServers[index].effectiveNamespaceID
        guard !namespaceID.isEmpty,
            !hasMCPNamespaceConflict(namespaceID, excluding: id)
        else { return false }
        return mutatePersistedState { mcpServers[index].namespaceID = namespaceID }
    }

    func delete(serverID: MCPServer.ID) {
        guard let server = mcpServer(serverID) else { return }
        let deleted = mutatePersistedState { mcpServers.removeAll { $0.id == serverID } }
        guard deleted else { return }
        setSecret(nil, for: server.credentialRef)
        mcpStatuses[serverID] = nil
    }

    func setServerEnabled(_ enabled: Bool, for id: MCPServer.ID) {
        mutatePersistedState {
            guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
            mcpServers[index].isEnabled = enabled
        }
    }

    /// What a successful `Connect` writes back.
    ///
    /// A tool keeps its access policy across rediscovery — otherwise every
    /// reconnect would silently undo the decision made about this server. A
    /// genuinely new tool arrives at the default, which means always asking.
    func setTools(_ discovered: [MCPTool], version: String, for id: MCPServer.ID) {
        mutatePersistedState {
            guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
            let previous = Dictionary(
                uniqueKeysWithValues: mcpServers[index].tools.map { ($0.id, $0) }
            )

            mcpServers[index].tools = discovered.map { tool in
                guard let old = previous[tool.id] else { return tool }
                var merged = tool
                merged.accessPolicy = old.accessPolicy
                return merged
            }
            mcpServers[index].negotiatedVersion = version
            mcpServers[index].lastConnectedAt = Date()
        }
    }

    func setToolAccessPolicy(
        _ policy: MCPTool.AccessPolicy, tool toolID: String, on serverID: MCPServer.ID
    ) {
        mutate(toolID, on: serverID) { $0.accessPolicy = policy }
    }

    private func mutate(
        _ toolID: String, on serverID: MCPServer.ID,
        _ change: (inout MCPTool) -> Void
    ) {
        mutatePersistedState {
            guard let index = mcpServers.firstIndex(where: { $0.id == serverID }) else { return }
            guard let slot = mcpServers[index].tools.firstIndex(where: { $0.id == toolID })
            else { return }
            change(&mcpServers[index].tools[slot])
        }
    }

    func setMCPStatus(_ status: ConnectionStatus, for id: MCPServer.ID) {
        mcpStatuses[id] = status
    }
}

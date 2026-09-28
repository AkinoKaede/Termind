import AgentKit
import Foundation
import TermindDomain

/// The single source of truth for model providers, their models, which model does
/// what, and the MCP servers.
///
/// Its own store rather than more fields on `HostLibraryModel`: that one is about
/// machines you connect to, this one is about model endpoints.
/// Provider and MCP configuration are projected from SwiftData in production
/// while previews can still construct an in-memory store.
@Observable
public final class AIConfigurationModel {
    public private(set) var modelProviders: [ModelProvider] = []

    /// What the user typed and picked for each provider's endpoint.
    ///
    /// Beside the providers rather than on them, because `ModelProvider` is
    /// AgentKit's type and this app does not get to add a field to it. Neither
    /// half survives a round trip through the composed result — a URL ending in
    /// `/messages` looks the same whether it was typed or appended, and
    /// `Automatic` looks the same as picking the format it resolved to — so
    /// there is nothing to derive it from and it has to be kept.
    ///
    /// A missing entry is not a broken one: it reads as `Automatic` over the
    /// provider.s stored `inferenceURL`, which resolves to the format already recorded
    /// there. The editor shows the same endpoint either way.
    private var endpoints: [ModelProvider.ID: ProviderEndpoint] = [:]

    public private(set) var mcpServers: [MCPServer] = []
    public let mcpAuthorization: MCPAuthorizationModel

    /// Explicit role assignments. Absent means "work it out" — see `resolve`.
    public private(set) var roles: [AIRole: AIModelRef] = [:]

    /// The last model picked in a conversation's model menu.
    ///
    /// Automatic uses this device-local choice when creating a conversation or
    /// repairing one whose fixed model is unavailable. An explicit Chat role
    /// assignment takes precedence, and existing valid conversations keep their
    /// own model. This selection is excluded from Settings sync.
    public private(set) var lastSelectedModel: AIModelRef?
    public var didChange: (() -> Void)?

    /// The approval posture new and otherwise-unset conversations follow.
    /// Stored in local preferences rather than provider configuration so it
    /// survives relaunches without becoming part of the synced SwiftData model.
    public private(set) var lastSelectedPermissionMode: AgentPermissionMode

    /// Live MCP connection state, keyed by server.
    ///
    /// Here rather than on `MCPServer` for the same reason `HostLibraryModel.statuses`
    /// is not on `Host`: it is session state, not user data, and it must never
    /// be persisted or synced.
    public private(set) var mcpStatuses: [MCPServer.ID: ConnectionStatus] = [:]

    /// Session cache for API keys and service-account JSON. Production reads
    /// through to the Data Protection Keychain; previews keep their fake secret
    /// in memory so demo data never creates a real Keychain item.
    private var secrets: [String: String] = [:]
    private let aiSecrets: (any AISecretStoring)?
    private let webSearchPersistence: (any AIWebSearchPersisting)?
    public private(set) var webSearch = AIWebSearchPreferences()
    private let keychain: any SecretStoring
    private let persistsSecrets: Bool
    private let permissionDefaults: UserDefaults?
    public private(set) var secretStorageError: String?
    private var persistence: (any AIConfigurationPersisting)?
    public private(set) var storageError: String?

    public init(
        modelProviders: [ModelProvider] = [],
        endpoints: [ModelProvider.ID: ProviderEndpoint] = [:],
        mcpServers: [MCPServer] = [],
        roles: [AIRole: AIModelRef] = [:],
        lastSelectedModel: AIModelRef? = nil,
        lastSelectedPermissionMode: AgentPermissionMode = .askForApproval,
        persistence: (any AIConfigurationPersisting)? = nil,
        secrets secretStore: any SecretStoring = InMemorySecretStore(),
        persistsSecrets: Bool = true,
        permissionDefaults: UserDefaults? = nil,
        aiSecrets: (any AISecretStoring)? = nil,
        webSearchPersistence: (any AIWebSearchPersisting)? = nil,
        mcpSecrets: (any MCPAuthorizationStoring)? = nil
    ) {
        self.mcpAuthorization = MCPAuthorizationModel(storage: mcpSecrets ?? InMemoryMCPAuthorizationStore())
        self.aiSecrets = aiSecrets
        self.webSearchPersistence = webSearchPersistence
        self.modelProviders = modelProviders
        self.endpoints = endpoints
        self.mcpServers = mcpServers
        self.roles = roles
        self.lastSelectedModel = lastSelectedModel
        self.lastSelectedPermissionMode =
            permissionDefaults
            .flatMap { $0.string(forKey: "assistant.permissionMode") }
            .flatMap(AgentPermissionMode.init(rawValue:))
            ?? lastSelectedPermissionMode
        self.persistence = persistence
        self.keychain = secretStore
        self.persistsSecrets = persistsSecrets
        self.permissionDefaults = permissionDefaults
        defer { mcpAuthorization.synchronize(self.mcpServers) }
        if let webSearchPersistence {
            do { webSearch = try webSearchPersistence.loadWebSearch() } catch {
                storageError = error.localizedDescription
            }
        }
        guard let persistence else { return }
        do {
            let loaded = try persistence.load()
            self.modelProviders = loaded.providers
            self.endpoints = loaded.endpoints
            self.roles = loaded.roles
            self.lastSelectedModel = loaded.lastSelectedModel
            self.mcpServers = loaded.mcpServers
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Reads

    public func modelProvider(_ id: ModelProvider.ID) -> ModelProvider? {
        modelProviders.first { $0.id == id }
    }

    /// What the editor shows for a provider's endpoint. Falls back to reading
    /// the composed URL as `Automatic` — see `endpoints`.
    public func endpoint(for id: ModelProvider.ID) -> ProviderEndpoint {
        if let stored = endpoints[id] { return stored }
        return ProviderEndpoint(url: modelProvider(id)?.inferenceURL ?? "")
    }

    /// Providers whose models may be offered anywhere. A provider with no
    /// credential is included: it may have hand-added models, and hiding it
    /// would make "why is my model missing" unanswerable from the picker.
    public var enabledModelProviders: [ModelProvider] {
        modelProviders.filter(\.isEnabled)
    }

    /// Resolves a ref to the pair it names, or `nil` if either half has since
    /// been deleted, renamed, or disabled.
    ///
    /// Every step of `resolve` runs through here, which is what stops a stale
    /// assignment from silently pointing at nothing.
    ///
    /// A missing URL is deliberately *not* one of the disqualifying conditions,
    /// for the same reason a missing credential is not: the model is sitting
    /// right there in Settings, and a picker that quietly skips it makes "why is
    /// my model missing" unanswerable. Sending to a blank URL now fails with a
    /// bad-URL error naming the problem, which is the better of the two — there
    /// is no default endpoint left for it to reach instead.
    public func lookup(_ ref: AIModelRef) -> (provider: ModelProvider, model: AIModel)? {
        guard
            let provider = modelProvider(ref.modelProviderID),
            provider.isEnabled,
            let model = provider.model(ref.modelID)
        else { return nil }
        return (provider, model)
    }

    public func lookupChat(_ ref: AIModelRef) -> (provider: ModelProvider, model: AIModel)? {
        guard let hit = lookup(ref), hit.provider.chatModels.contains(where: { $0.id == ref.modelID })
        else { return nil }
        return hit
    }

    /// The fallback of last resort: the first chat model of the first enabled
    /// provider, in the order the lists are shown.
    public var firstAvailableModel: AIModelRef? {
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
    ///   2. for Guardian, the highest-priority available review model
    ///   3. for other non-chat roles, whatever Chat resolves to
    ///   4. the last model picked in a conversation's menu
    ///   5. the first chat model of the first enabled provider
    ///
    /// Any step whose ref no longer resolves is skipped rather than returning
    /// nothing, so deleting a provider degrades the app instead of breaking it.
    /// The practical effect: add one provider, press Fetch, and the assistant
    /// works — the role pickers are for tuning, not for setup.
    public func resolve(_ role: AIRole) -> (provider: ModelProvider, model: AIModel)? {
        if let ref = roles[role], let hit = role == .chat ? lookupChat(ref) : lookup(ref) { return hit }
        if role == .guardian {
            if let codex = firstGuardianModel(named: "codex-auto-review") {
                return codex
            }
            for family in Self.guardianModelFamilies {
                if let newest = newestGuardianModel(
                    prefix: family.prefix, suffix: family.suffix
                ) {
                    return newest
                }
            }
            return resolveAutomaticChat()
        }
        if role != .chat, let chat = resolveAutomaticChat() { return chat }
        return resolveAutomaticChat()
    }

    private func resolveAutomaticChat() -> (provider: ModelProvider, model: AIModel)? {
        if let ref = roles[.chat], let hit = lookupChat(ref) { return hit }
        if let ref = lastSelectedModel, let hit = lookupChat(ref) { return hit }
        if let ref = firstAvailableModel, let hit = lookupChat(ref) { return hit }
        return nil
    }

    private static let guardianModelFamilies = [
        (prefix: "gpt-", suffix: "-luna"),
        (prefix: "claude-sonnet-", suffix: ""),
        (prefix: "gemini-", suffix: "-flash"),
        (prefix: "deepseek-v", suffix: "-flash"),
        (prefix: "glm-", suffix: "-flash"),
    ]

    private func firstGuardianModel(named id: String) -> (provider: ModelProvider, model: AIModel)? {
        for provider in enabledModelProviders {
            if let model = provider.chatModels.first(where: {
                let candidate = Self.normalizedModelID($0.id)
                return candidate == id
            }) {
                return (provider, model)
            }
        }
        return nil
    }

    private func newestGuardianModel(
        prefix: String, suffix: String
    ) -> (provider: ModelProvider, model: AIModel)? {
        var best: (provider: ModelProvider, model: AIModel, version: [Int])?
        for provider in enabledModelProviders {
            for model in provider.chatModels {
                let id = Self.normalizedModelID(model.id)
                guard let version = Self.guardianVersion(in: id, prefix: prefix, suffix: suffix)
                else { continue }
                if let best, !Self.version(version, isNewerThan: best.version) { continue }
                best = (provider, model, version)
            }
        }
        return best.map { ($0.provider, $0.model) }
    }

    private static func guardianVersion(
        in id: String, prefix: String, suffix: String
    ) -> [Int]? {
        guard id.hasPrefix(prefix), suffix.isEmpty || id.hasSuffix(suffix) else { return nil }
        let start = id.index(id.startIndex, offsetBy: prefix.count)
        let end = suffix.isEmpty ? id.endIndex : id.index(id.endIndex, offsetBy: -suffix.count)
        guard start < end else { return nil }
        let raw = id[start..<end]
        let components = raw.split(whereSeparator: { $0 == "." || $0 == "-" })
        let version = components.compactMap { Int($0) }
        guard !version.isEmpty, version.count == components.count else { return nil }
        return version
    }

    private static func version(_ lhs: [Int], isNewerThan rhs: [Int]) -> Bool {
        let count = max(lhs.count, rhs.count)
        for index in 0..<count {
            let left = lhs.indices.contains(index) ? lhs[index] : 0
            let right = rhs.indices.contains(index) ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func normalizedModelID(_ id: String) -> String {
        id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
    }

    /// A fixed conversation choice wins. New drafts and restored conversations
    /// receive a fixed choice from `AssistantModelSelectionController`; this
    /// fallback covers unavailable models until that controller saves a repair.
    public func resolve(conversation model: AIModelRef?) -> (provider: ModelProvider, model: AIModel)? {
        if let model, let hit = lookupChat(model) { return hit }
        return resolve(.chat)
    }

    /// An explicit conversation choice wins; otherwise the app-wide latest
    /// choice is the default. The latter begins at the safest posture.
    public func resolve(conversation permissionMode: AgentPermissionMode?) -> AgentPermissionMode {
        permissionMode ?? lastSelectedPermissionMode
    }

    /// Whether a role is showing an explicit choice or following the chain.
    /// The picker needs this to know when to show its unset tag.
    public func assignment(for role: AIRole) -> AIModelRef? {
        guard let ref = roles[role], lookup(ref) != nil else { return nil }
        return ref
    }

    /// Which roles would lose their explicit model if a provider were deleted.
    ///
    /// The counterpart of `HostLibraryModel.identities(using:)`, and used for the same
    /// reason: a delete button should say what it takes with it.
    public func roles(using modelProviderID: ModelProvider.ID) -> [AIRole] {
        AIRole.allCases.filter { roles[$0]?.modelProviderID == modelProviderID }
    }

    public func mcpServer(_ id: MCPServer.ID) -> MCPServer? {
        mcpServers.first { $0.id == id }
    }

    public func mcpStatus(of id: MCPServer.ID) -> ConnectionStatus {
        mcpStatuses[id] ?? .disconnected
    }

    public func hasMCPNamespaceConflict(_ namespaceID: String, excluding id: MCPServer.ID) -> Bool {
        !namespaceID.isEmpty
            && mcpServers.contains {
                $0.id != id && $0.effectiveNamespaceID == namespaceID
            }
    }

    /// Every discovered tool on enabled servers. Denied tools stay visible to
    /// the model so an attempted call receives an explicit policy refusal.
    public var availableTools: [(server: MCPServer, tool: MCPTool)] {
        usableMCPServers.flatMap { server in
            server.tools.map { (server, $0) }
        }
    }

    public var conflictingMCPServerIDs: Set<UUID> {
        var names = Set<String>()
        var conflicts = Set<UUID>()
        for server in mcpServers.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if !server.effectiveNamespaceID.isEmpty, !names.insert(server.effectiveNamespaceID).inserted {
                conflicts.insert(server.id)
            }
        }
        return conflicts
    }

    public var usableMCPServers: [MCPServer] {
        let conflicts = conflictingMCPServerIDs
        return mcpServers.filter { $0.isEnabled && !conflicts.contains($0.id) }
    }

    public func setWebSearch(_ value: AIWebSearchPreferences) {
        do {
            try webSearchPersistence?.saveWebSearch(value)
            webSearch = value
            storageError = nil
        } catch { storageError = error.localizedDescription }
    }

    /// Applies an already committed replica. It never calls the local write path.
    public func applyRemoteSnapshot(_ snapshot: AIConfigurationSnapshot, webSearch: AIWebSearchPreferences) {
        let localSelection = lastSelectedModel
        let previousServers = Dictionary(uniqueKeysWithValues: mcpServers.map { ($0.id, $0) })
        modelProviders = snapshot.providers
        endpoints = snapshot.endpoints
        roles = snapshot.roles
        lastSelectedModel = localSelection.flatMap { lookup($0) == nil ? nil : $0 }
        mcpServers = snapshot.mcpServers
        mcpAuthorization.synchronize(mcpServers)
        mcpStatuses = mcpStatuses.filter { id, _ in
            previousServers[id] == mcpServers.first { $0.id == id }
        }
        self.webSearch = webSearch
        secrets.removeAll()
        storageError = nil
        didChange?()
    }

    // MARK: - Secrets

    /// An empty result explicitly means no authentication. A missing result means
    /// a configured credential is unavailable; callers must not send anonymously.
    /// Vertex always requires a service account, even without a stored reference.
    public func modelSecret(for provider: ModelProvider) -> String? {
        if provider.usesVertexEndpoint && !ModelProviderForm.hasValidAddress(provider) { return nil }
        let reference = provider.effectiveCredentialRef
        if reference.isEmpty { return provider.usesVertexEndpoint ? nil : "" }
        guard let value = secret(for: reference), !value.isEmpty else { return nil }
        return value
    }

    /// The secret behind a `credentialRef`, loaded from the Termind Data
    /// Protection Keychain and cached only for this process.
    public func secret(for ref: String) -> String? {
        guard !ref.isEmpty else { return nil }
        if let aiSecrets, persistsSecrets {
            do {
                let value = try aiSecrets.string(for: ref)
                secretStorageError = nil
                return value
            } catch {
                secretStorageError = error.localizedDescription
                return nil
            }
        }
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
    public func setSecret(_ secret: String?, for ref: String) {
        guard !ref.isEmpty else { return }
        do {
            if persistsSecrets {
                if let aiSecrets {
                    try aiSecrets.setString(secret, for: ref)
                } else {
                    try keychain.setString(secret, for: ref, storage: .thisDevice)
                }
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
    public static func makeCredentialRef(_ kind: String = "key") -> String {
        "termind.ai.\(kind).\(UUID().uuidString)"
    }

    // MARK: - Model provider writes

    public func upsert(_ provider: ModelProvider) {
        var provider = provider
        let apiType = endpoints[provider.id]?.apiType ?? ModelAPIType(provider.apiFormat)
        provider.name = SavedName.resolve(provider.name, default: apiType.defaultProviderName)
        provider.models = provider.models.map(\.savingName)
        mutatePersistedState {
            if let index = modelProviders.firstIndex(where: { $0.id == provider.id }) {
                modelProviders[index] = provider
            } else {
                modelProviders.append(provider)
            }
        }
    }

    /// Commits a provider form and its endpoint together, without selecting a model.
    @discardableResult
    public func saveProvider(_ draft: ModelProvider, endpoint: ProviderEndpoint) -> Bool {
        mutatePersistedState {
            let (value, endpoint) = ModelProviderForm.normalized(draft, endpoint: endpoint)
            let removed = Set((modelProvider(value.id)?.models ?? []).map(\.id)).subtracting(value.models.map(\.id))
            for role in AIRole.allCases {
                if let ref = roles[role], ref.modelProviderID == value.id, removed.contains(ref.modelID) {
                    roles[role] = nil
                }
            }
            if let ref = lastSelectedModel, ref.modelProviderID == value.id, removed.contains(ref.modelID) {
                lastSelectedModel = nil
            }
            endpoints[value.id] = endpoint
            if let index = modelProviders.firstIndex(where: { $0.id == value.id }) {
                modelProviders[index] = value
            } else {
                modelProviders.append(value)
            }
        }
    }

    /// Derives and commits the request URL, base URL and format through the same form transaction.
    public func setEndpoint(_ endpoint: ProviderEndpoint, for id: ModelProvider.ID) {
        guard let provider = modelProvider(id) else { return }
        saveProvider(provider, endpoint: endpoint)
    }

    /// Removes a provider along with everything that only made sense while it
    /// existed: its secrets, the role assignments pointing at it, and the
    /// remembered selection if that was one of its models.
    ///
    /// The same discipline as `HostLibraryModel.delete(identityID:)`. Leaving any of
    /// these behind would give `resolve` a ref that looks valid and is not, and
    /// the failure would surface at send time rather than here.
    public func delete(modelProviderID: ModelProvider.ID) {
        guard let provider = modelProvider(modelProviderID) else { return }

        let deleted = mutatePersistedState {
            for role in roles(using: modelProviderID) {
                roles[role] = nil
            }
            if lastSelectedModel?.modelProviderID == modelProviderID {
                lastSelectedModel = nil
            }
            modelProviders.removeAll { $0.id == modelProviderID }
            endpoints[modelProviderID] = nil
        }
        guard deleted else { return }
        var failures: [String] = []
        for reference in Set([provider.credentialRef, provider.vertex.credentialRef]) where !reference.isEmpty {
            setSecret(nil, for: reference)
            if let error = secretStorageError { failures.append(error) }
        }
        secretStorageError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    public func setModelProviderEnabled(_ enabled: Bool, for id: ModelProvider.ID) {
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
    /// the server is better informed than a guess. Saved names remain user-owned.
    ///
    /// Not what the Fetch button calls. A fetch offers a list and the user picks
    /// from it (see `ModelListEditor`), so the additions arrive one at a time
    /// through `addModel`. This exists for a caller that really does mean "this
    /// is now the list".
    public func replaceModels(_ fetched: [AIModel], for id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            let previous = Dictionary(
                uniqueKeysWithValues: modelProviders[index].models.map { ($0.id, $0) }
            )
            let fetchedIDs = Set(fetched.map(\.id))
            let merged = fetched.map { fresh in
                var fresh = fresh
                fresh.displayName = SavedName.resolve(previous[fresh.id]?.displayName ?? "", default: fresh.displayName)
                fresh.reasoningProfile = previous[fresh.id]?.reasoningProfile
                fresh.isShownInAssistant =
                    previous[fresh.id]?.isShownInAssistant ?? fresh.isShownInAssistant
                return fresh.savingName
            }
            let kept = modelProviders[index].models.filter {
                $0.origin == .manual && !fetchedIDs.contains($0.id)
            }
            modelProviders[index].models = merged + kept.map(\.savingName)
            modelProviders[index].modelsFetchedAt = Date()
        }
    }

    /// Records that the endpoint was asked, whatever the user then chose to add.
    ///
    /// Separate from adding, because "when did I last check what this endpoint
    /// offers" is a different question from "what did I keep", and the answer to
    /// the first is useful even when the answer to the second is "nothing".
    public func markModelsFetched(for id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            modelProviders[index].modelsFetchedAt = Date()
        }
    }

    public func addModel(_ model: AIModel, to id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            guard !modelProviders[index].models.contains(where: { $0.id == model.id }) else { return }
            modelProviders[index].models.append(model.savingName)
        }
    }

    public func updateModel(_ model: AIModel, in id: ModelProvider.ID) {
        mutatePersistedState {
            guard let index = modelProviders.firstIndex(where: { $0.id == id }) else { return }
            guard let slot = modelProviders[index].models.firstIndex(where: { $0.id == model.id }) else { return }
            modelProviders[index].models[slot] = model.savingName
        }
    }

    /// Removes models, and unhooks anything that pointed at them.
    ///
    /// Same reasoning as `delete(modelProviderID:)`: a role holding a ref to a model
    /// that no longer exists is a failure deferred to send time.
    public func removeModels(_ ids: Set<String>, from modelProviderID: ModelProvider.ID) {
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

    public func assign(_ ref: AIModelRef?, to role: AIRole) {
        mutatePersistedState { roles[role] = ref }
    }

    /// Records a choice made in a conversation's model menu.
    ///
    /// Not an assignment: it feeds step 3 of `resolve`, so it changes the
    /// default without overwriting anything the user set in Settings.
    public func select(_ ref: AIModelRef) {
        mutatePersistedState { lastSelectedModel = ref }
    }

    /// Records a composer permission choice for subsequent unset conversations
    /// and future app launches. It does not alter command or MCP execution policy.
    public func select(_ permissionMode: AgentPermissionMode) {
        lastSelectedPermissionMode = permissionMode
        permissionDefaults?.set(permissionMode.rawValue, forKey: "assistant.permissionMode")
    }

    // MARK: - Provider persistence

    @discardableResult
    private func mutatePersistedState(_ mutation: () -> Void) -> Bool {
        let previous = persistedSnapshot
        mutation()
        guard let persistence else {
            mcpAuthorization.synchronize(mcpServers)
            didChange?()
            return true
        }
        do {
            try persistence.save(persistedSnapshot)
            mcpAuthorization.synchronize(mcpServers)
            storageError = nil
            didChange?()
            return true
        } catch {
            modelProviders = previous.providers
            endpoints = previous.endpoints
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
            endpoints: endpoints,
            roles: roles,
            lastSelectedModel: lastSelectedModel,
            mcpServers: mcpServers
        )
    }

    // MARK: - MCP writes

    public func upsert(_ server: MCPServer) {
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
    public func lockMCPNamespace(for id: MCPServer.ID) -> Bool {
        guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return false }
        if !mcpServers[index].namespaceID.isEmpty { return true }
        let namespaceID = mcpServers[index].effectiveNamespaceID
        guard !namespaceID.isEmpty,
            !hasMCPNamespaceConflict(namespaceID, excluding: id)
        else { return false }
        return mutatePersistedState { mcpServers[index].namespaceID = namespaceID }
    }

    public func delete(serverID: MCPServer.ID) {
        guard let server = mcpServer(serverID) else { return }
        let deleted = mutatePersistedState { mcpServers.removeAll { $0.id == serverID } }
        guard deleted else { return }
        setSecret(nil, for: server.credentialRef)
        mcpStatuses[serverID] = nil
    }

    public func setServerEnabled(_ enabled: Bool, for id: MCPServer.ID) {
        mutatePersistedState {
            guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
            mcpServers[index].isEnabled = enabled
        }
    }

    /// What a successful `Connect` writes back.
    ///
    /// A tool keeps its access policy across rediscovery — otherwise every
    /// reconnect would silently undo the decision made about this server. A
    /// genuinely new tool uses its Termind default: a non-destructive tool with
    /// `readOnlyHint == true` is approved, while every other tool asks.
    public func setTools(_ discovered: [MCPTool], version: String, for id: MCPServer.ID) {
        mutatePersistedState {
            guard let index = mcpServers.firstIndex(where: { $0.id == id }) else { return }
            let previous = Dictionary(
                uniqueKeysWithValues: mcpServers[index].tools.map { ($0.id, $0) }
            )

            mcpServers[index].tools = discovered.map { tool in
                var merged = tool
                merged.accessPolicy =
                    previous[tool.id]?.accessPolicy ?? merged.termindDefaultApprovalPolicy
                return merged
            }
            mcpServers[index].negotiatedVersion = version
            mcpServers[index].lastConnectedAt = Date()
        }
    }

    public func setToolAccessPolicy(
        _ policy: AgentToolDescriptor.ApprovalPolicy, tool toolID: String, on serverID: MCPServer.ID
    ) {
        mutate(toolID, on: serverID) {
            $0.accessPolicy = policy
        }
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

    public func setMCPStatus(_ status: ConnectionStatus, for id: MCPServer.ID) {
        mcpStatuses[id] = status
    }
}

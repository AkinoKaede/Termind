import AgentKit
import Foundation
import SwiftData

/// The provider row as schema V11 stored it: a vendor-named kind, an address
/// split into a base and a path, and the Vertex fields.
///
/// Frozen rather than described in prose, for the reason
/// `TermindSchemaV9Models` is: every `VersionedSchema` in the plan points at
/// live model types, so editing the current `PersistentModelProvider` would
/// silently rewrite what V11 *means* and leave an installed store recording a
/// version the plan no longer contains — which is a refusal to open, not a
/// migration. Keeping the old shape here is what gives V11→V12 two sides.
enum TermindSchemaV11Models {
    @Model
    final class PersistentModelProvider {
        @Attribute(.unique) var id: UUID = UUID()
        var name = ""
        var kind = "openAI"
        var isEnabled = true
        var baseURL = ""
        var apiPath = ""
        var credentialRef = ""
        var usesResponsesAPI = false
        var usesVertex = false
        var vertexProjectID = ""
        var vertexLocation = "global"
        var vertexCredentialRef = ""
        var vertexClientEmail = ""
        var modelsFetchedAt: Date?
        var sortIndex = 0

        init() {}
    }
}

@Model
final class PersistentModelProvider {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    /// `ModelAPIType.rawValue` — what the editor's picker is set to. Blank
    /// marks a row written before this column existed; see `legacyFold`.
    var apiType = ""
    /// The address as the user typed it.
    ///
    /// The *composed* address and the API format are not stored beside it. They
    /// are derived on read by the same `ProviderEndpoint` the editor writes
    /// through, so there is nothing for them to drift away from — one rule,
    /// applied in one place, whether the value is being shown or sent.
    var typedURL = ""
    var isEnabled = true
    var credentialRef = ""
    var modelsFetchedAt: Date?
    var sortIndex = 0

    // MARK: - Legacy (schema ≤ V11)

    /// Written by versions that split the address into a base and a path and
    /// named the protocol after a vendor. Read once by `legacyFold` and never
    /// written again; removable after the first shipped release.
    var kind = ""
    var baseURL = ""
    var apiPath = ""
    var usesResponsesAPI = false

    init(_ value: ModelProvider, endpoint: ProviderEndpoint, sortIndex: Int) {
        id = value.id
        name = value.name
        apiType = endpoint.apiType.rawValue
        typedURL = endpoint.url
        isEnabled = value.isEnabled
        credentialRef = value.credentialRef
        modelsFetchedAt = value.modelsFetchedAt
        self.sortIndex = sortIndex
    }

    func value(models: [AIModel]) -> ModelProvider {
        let endpoint = endpoint
        return ModelProvider(
            id: id,
            name: name,
            apiFormat: endpoint.format,
            isEnabled: isEnabled,
            inferenceURL: endpoint.requestURL,
            baseURL: endpoint.baseURL,
            credentialRef: credentialRef,
            models: models,
            modelsFetchedAt: modelsFetchedAt
        )
    }

    var endpoint: ProviderEndpoint {
        guard apiType.isEmpty else {
            return ProviderEndpoint(
                apiType: ModelAPIType(rawValue: apiType) ?? .automatic, url: typedURL
            )
        }
        return legacyFold
    }

    /// The pre-V12 columns read as one endpoint.
    ///
    /// The old shape had two fields and two fallbacks: a blank base URL meant
    /// the vendor's public host and a blank path meant that vendor's default
    /// endpoint. Both are gone, so the fold has to put back what they resolved
    /// to — otherwise a provider that worked yesterday comes back pointing
    /// nowhere. It lands on the *explicit* API type rather than `Automatic`,
    /// which reproduces the old behaviour exactly instead of re-deriving it.
    private var legacyFold: ProviderEndpoint {
        let format: ModelAPIFormat =
            switch kind {
            case "anthropic": .messages
            case "google": .generateContent
            default: usesResponsesAPI ? .responses : .chatCompletions
            }
        let base = baseURL.isEmpty ? Self.legacyDefaultBaseURL(kind) : baseURL
        let path = apiPath.isEmpty ? format.path : apiPath
        return ProviderEndpoint(apiType: ModelAPIType(format), url: base + path)
    }

    /// What `ModelProviderKind.defaultBaseURL` used to return. Kept here rather
    /// than in AgentKit because nothing but this fold still needs it, and an
    /// endpoint the app supplies on its own is exactly what the single URL
    /// field exists to stop.
    private static func legacyDefaultBaseURL(_ kind: String) -> String {
        switch kind {
        case "anthropic": "https://api.anthropic.com/v1"
        case "google": "https://generativelanguage.googleapis.com/v1beta"
        default: "https://api.openai.com/v1"
        }
    }
}

@Model
final class PersistentAIModel {
    @Attribute(.unique) var recordID: UUID = UUID()
    var providerID: UUID = UUID()
    var modelID = ""
    var displayName = ""
    var ownedBy = ""
    var kind = AIModel.Kind.chat.rawValue
    var input: [String] = []
    var output: [String] = []
    var abilities: [String] = []
    var contextLength: Int?
    var maxOutputTokens: Int?
    var iconHint = ""
    var createdAt: Date?
    var origin = AIModel.Origin.manual.rawValue
    var isShownInAssistant = true
    var reasoningProfileData: Data?
    var sortIndex = 0

    init(_ value: AIModel, providerID: UUID, sortIndex: Int) {
        self.providerID = providerID
        modelID = value.id
        displayName = value.displayName
        ownedBy = value.ownedBy
        kind = value.kind.rawValue
        input = value.input.map(\.rawValue).sorted()
        output = value.output.map(\.rawValue).sorted()
        abilities = value.abilities.map(\.rawValue).sorted()
        contextLength = value.contextLength
        maxOutputTokens = value.maxOutputTokens
        iconHint = value.iconHint
        createdAt = value.createdAt
        origin = value.origin.rawValue
        isShownInAssistant = value.isShownInAssistant
        reasoningProfileData = value.reasoningProfile.flatMap { try? JSONEncoder().encode($0) }
        self.sortIndex = sortIndex
    }

    var value: AIModel {
        var model = AIModel(id: modelID)
        model.displayName = displayName
        model.ownedBy = ownedBy
        model.kind = AIModel.Kind(rawValue: kind) ?? .chat
        model.input = Set(input.compactMap(AIModel.Modality.init(rawValue:)))
        if model.input.isEmpty { model.input = [.text] }
        model.output = Set(output.compactMap(AIModel.Modality.init(rawValue:)))
        if model.output.isEmpty { model.output = [.text] }
        model.abilities = Set(abilities.compactMap(AIModel.Ability.init(rawValue:)))
        model.contextLength = contextLength
        model.maxOutputTokens = maxOutputTokens
        model.iconHint = iconHint
        model.createdAt = createdAt
        model.origin = AIModel.Origin(rawValue: origin) ?? .manual
        model.isShownInAssistant = isShownInAssistant
        model.reasoningProfile = reasoningProfileData.flatMap {
            try? JSONDecoder().decode(ReasoningProfile.self, from: $0)
        }
        return model
    }
}

@Model
final class PersistentAIRoleAssignment {
    @Attribute(.unique) var role = ""
    var providerID: UUID = UUID()
    var modelID = ""

    init(role: AIRole, ref: AIModelRef) {
        self.role = role.rawValue
        providerID = ref.modelProviderID
        modelID = ref.modelID
    }
}

@Model
final class PersistentAISelection {
    @Attribute(.unique) var key = "lastSelectedModel"
    var providerID: UUID?
    var modelID: String?

    init(_ ref: AIModelRef?) {
        providerID = ref?.modelProviderID
        modelID = ref?.modelID
    }
}

@Model
final class PersistentMCPServer {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    var namespaceID = ""
    var transport = MCPServer.Transport.streamableHTTP.rawValue
    var url = ""
    var isEnabled = true
    var credentialRef = ""
    var headersData = Data()
    var toolsData = Data()
    var negotiatedVersion = ""
    var lastConnectedAt: Date?
    var sortIndex = 0

    init(_ value: MCPServer, sortIndex: Int) {
        id = value.id
        name = value.name
        namespaceID = value.namespaceID
        transport = value.transport.rawValue
        url = value.url
        isEnabled = value.isEnabled
        credentialRef = value.credentialRef
        headersData = (try? JSONEncoder().encode(value.headers)) ?? Data()
        toolsData = (try? JSONEncoder().encode(value.tools)) ?? Data()
        negotiatedVersion = value.negotiatedVersion
        lastConnectedAt = value.lastConnectedAt
        self.sortIndex = sortIndex
    }

    var value: MCPServer {
        MCPServer(
            id: id,
            name: name,
            namespaceID: namespaceID,
            transport: MCPServer.Transport(rawValue: transport) ?? .streamableHTTP,
            url: url,
            isEnabled: isEnabled,
            credentialRef: credentialRef,
            headers: (try? JSONDecoder().decode([MCPHeader].self, from: headersData)) ?? [],
            tools: (try? JSONDecoder().decode([MCPTool].self, from: toolsData)) ?? [],
            negotiatedVersion: negotiatedVersion,
            lastConnectedAt: lastConnectedAt
        )
    }
}

@MainActor
final class AIPersistence {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> AIConfigurationSnapshot {
        try load(preservingUnresolvedReferences: false)
    }

    func load(preservingUnresolvedReferences: Bool) throws -> AIConfigurationSnapshot {
        let modelRows = try context.fetch(
            FetchDescriptor<PersistentAIModel>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        let modelsByProvider = Dictionary(grouping: modelRows, by: \.providerID)
        let providerRows = try context.fetch(
            FetchDescriptor<PersistentModelProvider>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        var seenProviders: Set<UUID> = []
        var endpoints: [ModelProvider.ID: ProviderEndpoint] = [:]
        let providers = providerRows.compactMap { row -> ModelProvider? in
            guard seenProviders.insert(row.id).inserted else { return nil }
            var seenModels: Set<String> = []
            let models: [AIModel] = (modelsByProvider[row.id] ?? []).compactMap { modelRow -> AIModel? in
                guard seenModels.insert(modelRow.modelID).inserted else { return nil }
                return modelRow.value
            }
            endpoints[row.id] = row.endpoint
            return row.value(models: models)
        }

        func valid(_ ref: AIModelRef) -> Bool {
            providers.first(where: { $0.id == ref.modelProviderID })?.model(ref.modelID) != nil
        }

        var roles: [AIRole: AIModelRef] = [:]
        for row in try context.fetch(FetchDescriptor<PersistentAIRoleAssignment>()) {
            guard let role = AIRole(rawValue: row.role) else { continue }
            let ref = AIModelRef(modelProviderID: row.providerID, modelID: row.modelID)
            if preservingUnresolvedReferences || valid(ref) { roles[role] = ref }
        }

        let selectionRow = try context.fetch(FetchDescriptor<PersistentAISelection>()).first
        let lastSelectedModel: AIModelRef? = {
            guard let providerID = selectionRow?.providerID,
                let modelID = selectionRow?.modelID
            else { return nil }
            let ref = AIModelRef(modelProviderID: providerID, modelID: modelID)
            return preservingUnresolvedReferences || valid(ref) ? ref : nil
        }()

        let mcpRows = try context.fetch(
            FetchDescriptor<PersistentMCPServer>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        var seenMCPServers: Set<UUID> = []
        let mcpServers = mcpRows.compactMap { row -> MCPServer? in
            guard seenMCPServers.insert(row.id).inserted else { return nil }
            return row.value
        }

        return AIConfigurationSnapshot(
            providers: providers,
            endpoints: endpoints,
            roles: roles,
            lastSelectedModel: lastSelectedModel,
            mcpServers: mcpServers
        )
    }

    func save(_ snapshot: AIConfigurationSnapshot) throws {
        try context.commit { try replace(snapshot) }
    }

    /// Stages rows in the caller-owned transaction.
    func replace(_ snapshot: AIConfigurationSnapshot) throws {
        try context.delete(model: PersistentAIModel.self)
        try context.delete(model: PersistentModelProvider.self)
        try context.delete(model: PersistentAIRoleAssignment.self)
        try context.delete(model: PersistentAISelection.self)
        try context.delete(model: PersistentMCPServer.self)

        for (providerIndex, provider) in snapshot.providers.enumerated() {
            // A provider with no recorded endpoint is read back as
            // `Automatic` over its composed URL, which resolves to the same
            // format it already has — see `AIConfigurationModel.endpoints`.
            let endpoint =
                snapshot.endpoints[provider.id] ?? ProviderEndpoint(url: provider.inferenceURL)
            context.insert(
                PersistentModelProvider(provider, endpoint: endpoint, sortIndex: providerIndex)
            )
            for (modelIndex, model) in provider.models.enumerated() {
                context.insert(
                    PersistentAIModel(model, providerID: provider.id, sortIndex: modelIndex)
                )
            }
        }
        for role in AIRole.allCases {
            guard let ref = snapshot.roles[role] else { continue }
            context.insert(PersistentAIRoleAssignment(role: role, ref: ref))
        }
        context.insert(PersistentAISelection(snapshot.lastSelectedModel))
        for (serverIndex, server) in snapshot.mcpServers.enumerated() {
            context.insert(PersistentMCPServer(server, sortIndex: serverIndex))
        }
    }
}

extension AIPersistence: AIConfigurationPersisting {}

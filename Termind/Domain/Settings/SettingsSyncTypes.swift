import AgentKit
import Foundation

/// App-owned wire types: only persisted configuration crosses this boundary.
nonisolated struct SyncedAIModel: Codable, Hashable, Sendable {
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

    init(_ value: AIModel) {
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
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        reasoningProfileData = value.reasoningProfile.flatMap { try? encoder.encode($0) }
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

nonisolated struct SyncedModelProvider: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var endpoint: ProviderEndpoint
    var isEnabled: Bool
    var credentialRef: String
    var models: [SyncedAIModel]
    var modelsFetchedAt: Date?
    var sortIndex: Int

    init(_ provider: ModelProvider, endpoint: ProviderEndpoint, sortIndex: Int) {
        id = provider.id
        name = provider.name
        self.endpoint = endpoint
        isEnabled = provider.isEnabled
        credentialRef = provider.credentialRef
        models = provider.models.map(SyncedAIModel.init)
        modelsFetchedAt = provider.modelsFetchedAt
        self.sortIndex = sortIndex
    }

    var value: ModelProvider {
        ModelProvider(
            id: id, name: name, apiFormat: endpoint.format, isEnabled: isEnabled,
            inferenceURL: endpoint.requestURL, baseURL: endpoint.baseURL,
            credentialRef: credentialRef, models: models.map(\.value), modelsFetchedAt: modelsFetchedAt)
    }
}

nonisolated struct SyncedMCPServer: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var namespaceID: String
    var transport: MCPServer.Transport
    var url: String
    var isEnabled: Bool
    var credentialRef: String
    var headers: [MCPHeader]
    var tools: [MCPTool]
    var sortIndex: Int

    init(_ server: MCPServer, sortIndex: Int) {
        id = server.id
        name = server.name
        namespaceID = server.namespaceID
        transport = server.transport
        url = server.url
        isEnabled = server.isEnabled
        credentialRef = server.credentialRef
        headers = server.headers
        tools = server.tools
        self.sortIndex = sortIndex
    }

    var value: MCPServer {
        MCPServer(
            id: id, name: name, namespaceID: namespaceID, transport: transport,
            url: url, isEnabled: isEnabled, credentialRef: credentialRef, headers: headers, tools: tools)
    }
}

nonisolated struct AIWebSearchPreferences: Codable, Hashable, Sendable {
    var isEnabled = true
    var prefersBuiltIn = true
}

nonisolated enum SettingsRecordKind: String, Codable, CaseIterable, Sendable {
    case provider, mcpServer, skill, role, selection, webSearch, terminal
}

nonisolated struct SettingsRecordKey: Codable, Hashable, Sendable {
    var kind: SettingsRecordKind
    var id: String
    var recordName: String { "v1/\(kind.rawValue)/\(id)" }

    init(kind: SettingsRecordKind, id: String) {
        self.kind = kind
        self.id = id
    }

    init?(recordName: String) {
        let parts = recordName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
            let kind = SettingsRecordKind(rawValue: String(parts[1]))
        else { return nil }
        let id = String(parts[2])
        switch kind {
        case .provider, .mcpServer, .skill:
            guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return nil }
        case .role:
            guard AIRole(rawValue: id) != nil else { return nil }
        case .selection, .webSearch, .terminal:
            guard id == "default" else { return nil }
        }
        self.init(kind: kind, id: id)
    }
}

nonisolated enum SettingsRecordPayload: Codable, Hashable, Sendable {
    case provider(SyncedModelProvider)
    case mcpServer(SyncedMCPServer)
    case skill(AgentSkill, sortIndex: Int)
    case role(AIRole, AIModelRef?)
    case selection(AIModelRef?)
    case webSearch(AIWebSearchPreferences)
    case terminal(TerminalPreferences)

    var key: SettingsRecordKey {
        switch self {
        case .provider(let value): .init(kind: .provider, id: value.id.uuidString.lowercased())
        case .mcpServer(let value): .init(kind: .mcpServer, id: value.id.uuidString.lowercased())
        case .skill(let value, _): .init(kind: .skill, id: value.id.uuidString.lowercased())
        case .role(let role, _): .init(kind: .role, id: role.rawValue)
        case .selection: .init(kind: .selection, id: "default")
        case .webSearch: .init(kind: .webSearch, id: "default")
        case .terminal: .init(kind: .terminal, id: "default")
        }
    }
}

nonisolated struct SettingsEnvelope: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1
    var formatVersion = Self.currentFormatVersion
    var key: SettingsRecordKey
    var version: VaultVersion
    var isDeleted = false
    var payload: SettingsRecordPayload?

    var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && SettingsRecordKey(recordName: key.recordName) == key
            && (isDeleted ? payload == nil : payload?.key == key)
    }
}

nonisolated struct SettingsMutationSet: Equatable, Sendable {
    var keys: Set<SettingsRecordKey> = []
    static let empty = Self()
    var isEmpty: Bool { keys.isEmpty }
}

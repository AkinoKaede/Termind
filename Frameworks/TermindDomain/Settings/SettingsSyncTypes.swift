import AgentKit
import Foundation

/// App-owned wire types: only persisted configuration crosses this boundary.
public nonisolated struct SyncedAIModel: Codable, Hashable, Sendable {
    public var modelID = ""
    public var displayName = ""
    public var ownedBy = ""
    public var kind = AIModel.Kind.chat.rawValue
    public var input: [String] = []
    public var output: [String] = []
    public var abilities: [String] = []
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var iconHint = ""
    public var createdAt: Date?
    public var origin = AIModel.Origin.manual.rawValue
    public var isShownInAssistant = true
    public var reasoningProfileData: Data?

    public init(_ value: AIModel) {
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

    public var value: AIModel {
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

public nonisolated struct SyncedModelProvider: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var endpoint: ProviderEndpoint
    public var isEnabled: Bool
    public var credentialRef: String
    public var models: [SyncedAIModel]
    public var modelsFetchedAt: Date?
    public var sortIndex: Int

    public init(_ provider: ModelProvider, endpoint: ProviderEndpoint, sortIndex: Int) {
        id = provider.id
        name = provider.name
        self.endpoint = endpoint
        isEnabled = provider.isEnabled
        credentialRef = provider.credentialRef
        models = provider.models.map(SyncedAIModel.init)
        modelsFetchedAt = provider.modelsFetchedAt
        self.sortIndex = sortIndex
    }

    public var value: ModelProvider {
        ModelProvider(
            id: id, name: name, apiFormat: endpoint.format, isEnabled: isEnabled,
            inferenceURL: endpoint.requestURL, baseURL: endpoint.baseURL,
            credentialRef: credentialRef, models: models.map(\.value), modelsFetchedAt: modelsFetchedAt)
    }
}

public nonisolated struct SyncedMCPServer: Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var namespaceID: String
    public var transport: MCPServer.Transport
    public var url: String
    public var isEnabled: Bool
    public var credentialRef: String
    public var headers: [MCPHeader]
    public var tools: [MCPTool]
    public var sortIndex: Int

    public init(_ server: MCPServer, sortIndex: Int) {
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

    public var value: MCPServer {
        MCPServer(
            id: id, name: name, namespaceID: namespaceID, transport: transport,
            url: url, isEnabled: isEnabled, credentialRef: credentialRef, headers: headers, tools: tools)
    }
}

public nonisolated struct AIWebSearchPreferences: Codable, Hashable, Sendable {
    public var isEnabled = true
    public var prefersBuiltIn = true
    public init(isEnabled: Bool = true, prefersBuiltIn: Bool = true) {
        self.isEnabled = isEnabled
        self.prefersBuiltIn = prefersBuiltIn
    }

}

public nonisolated enum SettingsRecordKind: String, Codable, CaseIterable, Sendable {
    case provider, mcpServer, skill, role, selection, webSearch, terminal

    /// `selection` remains decodable for compatibility with existing CloudKit
    /// records, but the conversation model picker is a device-local preference.
    public var participatesInSync: Bool { self != .selection }
}

public nonisolated struct SettingsRecordKey: Codable, Hashable, Sendable {
    public var kind: SettingsRecordKind
    public var id: String
    public var recordName: String { "v1/\(kind.rawValue)/\(id)" }

    public init(kind: SettingsRecordKind, id: String) {
        self.kind = kind
        self.id = id
    }

    public init?(recordName: String) {
        let parts = recordName.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "v1",
            let kind = SettingsRecordKind(rawValue: String(parts[1]))
        else { return nil }
        let id = String(parts[2])
        switch kind {
        case .provider, .mcpServer, .skill:
            guard let uuid = UUID(uuidString: id), uuid.uuidString.lowercased() == id else { return nil }
        case .role:
            guard AIRole(rawValue: id) != nil || id == "securityReview" else { return nil }
        case .selection, .webSearch, .terminal:
            guard id == "default" else { return nil }
        }
        self.init(kind: kind, id: id)
    }
}

public nonisolated enum SettingsRecordPayload: Codable, Hashable, Sendable {
    case provider(SyncedModelProvider)
    case mcpServer(SyncedMCPServer)
    case skill(AgentSkill, sortIndex: Int)
    case role(AIRole, AIModelRef?)
    case selection(AIModelRef?)
    case webSearch(AIWebSearchPreferences)
    case terminal(TerminalPreferences)

    public var key: SettingsRecordKey {
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

public nonisolated struct SettingsEnvelope: Codable, Hashable, Sendable {
    public static let currentFormatVersion = 1
    public var formatVersion = Self.currentFormatVersion
    public var key: SettingsRecordKey
    public var version: VaultVersion
    public var isDeleted = false
    public var payload: SettingsRecordPayload?

    public init(
        formatVersion: Int = SettingsEnvelope.currentFormatVersion,
        key: SettingsRecordKey, version: VaultVersion, isDeleted: Bool = false,
        payload: SettingsRecordPayload? = nil
    ) {
        self.formatVersion = formatVersion
        self.key = key
        self.version = version
        self.isDeleted = isDeleted
        self.payload = payload
    }

    public var isValid: Bool {
        formatVersion == Self.currentFormatVersion
            && SettingsRecordKey(recordName: key.recordName) == key
            && (isDeleted ? payload == nil : payload?.key == key)
    }
}

public nonisolated struct SettingsMutationSet: Equatable, Sendable {
    public var keys: Set<SettingsRecordKey> = []
    public static let empty = Self()
    public var isEmpty: Bool { keys.isEmpty }
    public init(keys: Set<SettingsRecordKey> = []) {
        self.keys = keys
    }

}

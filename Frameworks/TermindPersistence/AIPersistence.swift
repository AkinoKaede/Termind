// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindDomain

/// The provider row as schema V11 stored it: a vendor-named kind, an address
/// split into a base and a path, and the Vertex fields.
///
/// Frozen rather than described in prose, for the reason
/// `TermindSchemaV9Models` is: every `VersionedSchema` in the plan points at
/// live model types, so editing the current `PersistentModelProvider` would
/// silently rewrite what V11 *means* and leave an installed store recording a
/// version the plan no longer contains — which is a refusal to open, not a
/// migration. Keeping the old shape here is what gives V11→V12 two sides.
public enum TermindSchemaV11Models {
    @Model
    public final class PersistentModelProvider {
        @Attribute(.unique) public var id: UUID = UUID()
        public var name = ""
        public var kind = "openAI"
        public var isEnabled = true
        public var baseURL = ""
        public var apiPath = ""
        public var credentialRef = ""
        public var usesResponsesAPI = false
        public var usesVertex = false
        public var vertexProjectID = ""
        public var vertexLocation = "global"
        public var vertexCredentialRef = ""
        public var vertexClientEmail = ""
        public var modelsFetchedAt: Date?
        public var sortIndex = 0

        public init() {}
    }
}

@Model
public final class PersistentModelProvider {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    /// `ModelAPIType.rawValue` — what the editor's picker is set to. Blank
    /// marks a row written before this column existed; see `legacyFold`.
    public var apiType = ""
    /// The address as the user typed it.
    ///
    /// The *composed* address and the API format are not stored beside it. They
    /// are derived on read by the same `ProviderEndpoint` the editor writes
    /// through, so there is nothing for them to drift away from — one rule,
    /// applied in one place, whether the value is being shown or sent.
    public var typedURL = ""
    public var isEnabled = true
    public var credentialRef = ""
    public var modelsFetchedAt: Date?
    public var sortIndex = 0

    // MARK: - Legacy (schema ≤ V11)

    /// Written by versions that split the address into a base and a path and
    /// named the protocol after a vendor. Read once by `legacyFold` and never
    /// written again; removable after the first shipped release.
    public var kind = ""
    public var baseURL = ""
    public var apiPath = ""
    public var usesResponsesAPI = false

    public init(_ value: ModelProvider, endpoint: ProviderEndpoint, sortIndex: Int) {
        id = value.id
        name = value.name
        apiType = endpoint.apiType.rawValue
        typedURL = endpoint.url
        isEnabled = value.isEnabled
        credentialRef = value.credentialRef
        modelsFetchedAt = value.modelsFetchedAt
        self.sortIndex = sortIndex
    }

    public func value(models: [AIModel]) -> ModelProvider {
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

    public var endpoint: ProviderEndpoint {
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
public final class PersistentAIModel {
    @Attribute(.unique) public var recordID: UUID = UUID()
    public var providerID: UUID = UUID()
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
    public var sortIndex = 0

    public init(_ value: AIModel, providerID: UUID, sortIndex: Int) {
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

@Model
public final class PersistentAIRoleAssignment {
    @Attribute(.unique) public var role = ""
    public var providerID: UUID = UUID()
    public var modelID = ""

    public init(role: AIRole, ref: AIModelRef) {
        self.role = role.rawValue
        providerID = ref.modelProviderID
        modelID = ref.modelID
    }
}

@Model
public final class PersistentAISelection {
    @Attribute(.unique) public var key = "lastSelectedModel"
    public var providerID: UUID?
    public var modelID: String?

    public init(_ ref: AIModelRef?) {
        providerID = ref?.modelProviderID
        modelID = ref?.modelID
    }
}

@Model
public final class PersistentMCPServer {
    @Attribute(.unique) public var id: UUID = UUID()
    public var name = ""
    public var namespaceID = ""
    public var transport = MCPServer.Transport.streamableHTTP.rawValue
    public var url = ""
    public var isEnabled = true
    public var credentialRef = ""
    public var headersData = Data()
    public var toolsData = Data()
    public var negotiatedVersion = ""
    public var lastConnectedAt: Date?
    public var sortIndex = 0

    public init(_ value: MCPServer, sortIndex: Int) {
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

    public var value: MCPServer {
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

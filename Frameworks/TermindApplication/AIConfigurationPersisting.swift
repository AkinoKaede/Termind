import AgentKit
import Foundation
import TermindDomain

public nonisolated struct AIConfigurationSnapshot: Sendable {
    public var providers: [ModelProvider]
    /// What was typed and picked per provider — see `AIConfigurationModel.endpoints`.
    public var endpoints: [ModelProvider.ID: ProviderEndpoint] = [:]
    public var roles: [AIRole: AIModelRef]
    public var lastSelectedModel: AIModelRef?
    public var mcpServers: [MCPServer] = []
    public init(
        providers: [ModelProvider], endpoints: [ModelProvider.ID: ProviderEndpoint] = [:], roles: [AIRole: AIModelRef],
        lastSelectedModel: AIModelRef? = nil, mcpServers: [MCPServer] = []
    ) {
        self.providers = providers
        self.endpoints = endpoints
        self.roles = roles
        self.lastSelectedModel = lastSelectedModel
        self.mcpServers = mcpServers
    }

}

@MainActor
public protocol AIConfigurationPersisting: AnyObject {
    func load() throws -> AIConfigurationSnapshot
    func save(_ snapshot: AIConfigurationSnapshot) throws
}

@MainActor
public protocol AIWebSearchPersisting: AnyObject {
    func loadWebSearch() throws -> AIWebSearchPreferences
    func saveWebSearch(_ value: AIWebSearchPreferences) throws
}

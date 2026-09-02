import AgentKit
import Foundation

nonisolated struct AIConfigurationSnapshot: Sendable {
    var providers: [ModelProvider]
    var roles: [AIRole: AIModelRef]
    var lastSelectedModel: AIModelRef?
    var mcpServers: [MCPServer] = []
}

@MainActor
protocol AIConfigurationPersisting: AnyObject {
    func load() throws -> AIConfigurationSnapshot
    func save(_ snapshot: AIConfigurationSnapshot) throws
}

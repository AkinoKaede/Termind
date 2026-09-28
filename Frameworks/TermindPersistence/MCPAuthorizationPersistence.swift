import AgentKit
import Foundation
import SwiftData

/// A sidecar preserves the shapes of historical MCP server schemas. This contains no credentials.
@Model
public final class PersistentMCPOAuthConfiguration {
    @Attribute(.unique) public var serverID: UUID = UUID()
    public var issuer = ""
    public var clientID = ""

    public init(serverID: UUID, configuration: MCPOAuthConfiguration) {
        self.serverID = serverID
        issuer = configuration.issuer
        clientID = configuration.clientID
    }

    public var value: MCPOAuthConfiguration { .init(issuer: issuer, clientID: clientID) }
}

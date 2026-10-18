import Foundation
import SwiftData

/// Discovery metadata is separate so historical MCP server schemas remain unchanged.
@Model
public final class PersistentMCPServerMetadata {
    @Attribute(.unique) public var serverID: UUID = UUID()
    public var serverDescription = ""

    public init(serverID: UUID, serverDescription: String) {
        self.serverID = serverID
        self.serverDescription = serverDescription
    }
}

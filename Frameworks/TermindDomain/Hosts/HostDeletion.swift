import Foundation

public nonisolated struct HostDeletionImpact: Equatable, Sendable {
    public var jumpHostReferences: Int
    public var snippetReferences: Int
    public var forwardingRules: Int
    public init(jumpHostReferences: Int, snippetReferences: Int, forwardingRules: Int) {
        self.jumpHostReferences = jumpHostReferences
        self.snippetReferences = snippetReferences
        self.forwardingRules = forwardingRules
    }

}

public nonisolated struct HostDeletionPayload: Codable, Hashable, Sendable {
    public var hostID: Host.ID
    public var forwardingRuleIDs: [PortForwardingRule.ID]
    public init(hostID: Host.ID, forwardingRuleIDs: [PortForwardingRule.ID]) {
        self.hostID = hostID
        self.forwardingRuleIDs = forwardingRuleIDs
    }

}

public nonisolated enum HostDeletionOutbox {
    public static let eventType = "host.deletion-requested.v1"
    public static let closeWorkspaces = "host-delete.10-close-workspaces"
    public static let cancelTransfers = "host-delete.20-cancel-transfers"
    public static let stopForwardings = "host-delete.30-stop-forwardings"
    public static let clearReferences = "host-delete.40-clear-references"
    public static let finalize = "host-delete.50-finalize"

    public static let handlerIDs = [
        closeWorkspaces, cancelTransfers, stopForwardings, clearReferences, finalize,
    ]
}

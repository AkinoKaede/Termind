import Foundation

nonisolated struct HostDeletionImpact: Equatable, Sendable {
    var jumpHostReferences: Int
    var snippetReferences: Int
    var forwardingRules: Int
}

nonisolated struct HostDeletionPayload: Codable, Hashable, Sendable {
    var hostID: Host.ID
    var forwardingRuleIDs: [PortForwardingRule.ID]
}

nonisolated enum HostDeletionOutbox {
    static let eventType = "host.deletion-requested.v1"
    static let closeWorkspaces = "host-delete.10-close-workspaces"
    static let cancelTransfers = "host-delete.20-cancel-transfers"
    static let stopForwardings = "host-delete.30-stop-forwardings"
    static let clearReferences = "host-delete.40-clear-references"
    static let finalize = "host-delete.50-finalize"

    static let handlerIDs = [
        closeWorkspaces, cancelTransfers, stopForwardings, clearReferences, finalize,
    ]
}

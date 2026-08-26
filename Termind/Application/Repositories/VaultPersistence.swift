import Foundation

nonisolated struct VaultSnapshot: Sendable {
    var hosts: [Host] = []
    var groups: [HostGroup] = []
    var identities: [Identity] = []
    var keys: [SSHKeyRef] = []
    var knownHosts: [KnownHostEntry] = []
    var snippets: [Snippet] = []
    var snippetPackages: [SnippetPackage] = []
    var portForwardings: [PortForwardingRule] = []
}

@MainActor
protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot) throws
}


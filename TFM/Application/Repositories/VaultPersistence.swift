import Foundation
import TermindDomain

import struct TermindDomain.Host

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

nonisolated struct VaultRemoteApplyResult: Sendable {
    var snapshot: VaultSnapshot
    var acceptedKeys: Set<VaultRecordKey>
    var needsUpload: Set<VaultRecordKey>
}

@MainActor
protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult
}

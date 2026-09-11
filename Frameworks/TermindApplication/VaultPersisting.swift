import TermindDomain

@MainActor
public protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult
}

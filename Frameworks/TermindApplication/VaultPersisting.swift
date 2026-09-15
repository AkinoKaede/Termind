import Foundation
import TermindDomain

@MainActor
public protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet
    func saveIdentityLastUsedAt(_ updates: [Identity.ID: Date]) throws
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult
    func modificationDates() throws -> [VaultRecordKey: Date]
}

extension VaultPersisting {
    public func modificationDates() throws -> [VaultRecordKey: Date] { [:] }
}

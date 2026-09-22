import Foundation
import TermindDomain

@MainActor
public protocol VaultPersisting: AnyObject {
    func load() throws -> VaultSnapshot
    func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>) throws -> VaultMutationSet
    func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult
    func modificationDates() throws -> [VaultRecordKey: Date]
}

extension VaultPersisting {
    public func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        try save(snapshot, touching: [])
    }
    public func modificationDates() throws -> [VaultRecordKey: Date] { [:] }
}

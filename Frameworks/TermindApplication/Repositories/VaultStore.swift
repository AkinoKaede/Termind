import Foundation
import TermindDomain

/// Persistence boundary shared by the Vault feature models. It keeps concrete
/// storage and sync notifications out of aggregate models while preserving the
/// existing `VaultSnapshot` transaction and on-disk schema.
@MainActor
public final class VaultStore {
    private let persistence: (any VaultPersisting)?
    public var didPersist: (() -> Void)?
    public var didRecordChanges: ((VaultMutationSet) -> Void)?

    public init(persistence: (any VaultPersisting)? = nil) {
        self.persistence = persistence
    }

    public func load(fallback: VaultSnapshot) throws -> VaultSnapshot {
        try persistence?.load() ?? fallback
    }

    public func save(_ snapshot: VaultSnapshot) throws {
        if let persistence {
            let mutations = try persistence.save(snapshot)
            didRecordChanges?(mutations)
        }
        didPersist?()
    }

    /// A remote projection is already persisted by the sync engine. Aggregate
    /// models only need to refresh repository projections after accepting it.
    public func didApplyRemoteSnapshot() {
        didPersist?()
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

/// Persistence boundary shared by the Vault feature models. It keeps concrete
/// storage and sync notifications out of aggregate models while preserving the
/// existing `VaultSnapshot` transaction and on-disk schema.
@MainActor
public final class VaultStore {
    private let persistence: (any VaultPersisting)?
    private var modificationDates: [VaultRecordKey: Date] = [:]
    public var didPersist: (() -> Void)?
    public var didRecordChanges: ((VaultMutationSet) -> Void)?

    public init(persistence: (any VaultPersisting)? = nil) {
        self.persistence = persistence
    }

    public func load(fallback: VaultSnapshot) throws -> VaultSnapshot {
        let snapshot = try persistence?.load() ?? fallback
        refreshModificationDates()
        return snapshot
    }

    public func save(_ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey> = []) throws {
        if let persistence {
            let mutations = try persistence.save(snapshot, touching: keys)
            refreshModificationDates()
            didRecordChanges?(mutations)
        }
        didPersist?()
    }

    public func modifiedAt(for key: VaultRecordKey) -> Date? {
        modificationDates[key]
    }

    /// A remote projection is already persisted by the sync engine. Aggregate
    /// models only need to refresh repository projections after accepting it.
    public func didApplyRemoteSnapshot() {
        refreshModificationDates()
        didPersist?()
    }

    private func refreshModificationDates() {
        guard let dates = try? persistence?.modificationDates() else { return }
        modificationDates = dates
    }
}

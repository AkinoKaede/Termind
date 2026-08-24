import Foundation

nonisolated struct HostLibrarySnapshot: Equatable, Sendable {
    var hosts: [Host]
    var groups: [HostGroup]

    static let empty = HostLibrarySnapshot(hosts: [], groups: [])
}

@MainActor
protocol HostRepository: AnyObject {
    func snapshot() throws -> RepositoryChange<HostLibrarySnapshot>
    func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>>
    func refresh() throws
    func upsertHost(_ host: Host) throws
    func deletionImpact(for hostID: Host.ID) throws -> HostDeletionImpact
    func requestHostDeletion(_ hostID: Host.ID) throws
    func clearReferencesForDeletedHost(_ hostID: Host.ID) throws
    func finalizeHostDeletion(_ hostID: Host.ID) throws
}

/// Compatibility source used by previews and focused unit tests while features
/// are migrated away from HostStore. It is deliberately read-only.
@MainActor
final class HostStoreRepositoryAdapter: HostRepository {
    private let store: HostStore
    private var revision: Int64 = 0
    private var continuations: [UUID: AsyncStream<RepositoryChange<HostLibrarySnapshot>>.Continuation]
        = [:]

    init(store: HostStore) {
        self.store = store
    }

    func snapshot() throws -> RepositoryChange<HostLibrarySnapshot> {
        RepositoryChange(
            revision: revision,
            value: HostLibrarySnapshot(hosts: store.hosts, groups: store.groups),
            reason: .initial
        )
    }

    func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(try! snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func refresh() throws {
        revision &+= 1
        let change = RepositoryChange(
            revision: revision,
            value: HostLibrarySnapshot(hosts: store.hosts, groups: store.groups),
            reason: .refresh
        )
        for continuation in continuations.values { continuation.yield(change) }
    }

    func upsertHost(_ host: Host) throws {
        store.upsert(host)
        try refresh()
    }

    func deletionImpact(for hostID: Host.ID) throws -> HostDeletionImpact {
        HostDeletionImpact(
            jumpHostReferences: store.hosts.filter { $0.jumpHostID == hostID }.count,
            snippetReferences: store.snippets.filter { $0.targetHostIDs.contains(hostID) }.count,
            forwardingRules: store.portForwardings(for: hostID).count
        )
    }

    func requestHostDeletion(_ hostID: Host.ID) throws {
        store.delete(hostID: hostID)
        try refresh()
    }

    func clearReferencesForDeletedHost(_ hostID: Host.ID) throws {}
    func finalizeHostDeletion(_ hostID: Host.ID) throws {}
}

import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
public final class InMemoryHostRepository: HostRepository {
    private var value: HostLibrarySnapshot
    private var revision: Int64 = 0
    private var continuations: [UUID: AsyncStream<RepositoryChange<HostLibrarySnapshot>>.Continuation] = [:]

    public init(snapshot: HostLibrarySnapshot = .empty) { value = snapshot }

    public func snapshot() throws -> RepositoryChange<HostLibrarySnapshot> {
        RepositoryChange(
            revision: revision,
            value: value,
            reason: .initial
        )
    }

    public func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.yield(try! snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    public func refresh() throws {
        revision &+= 1
        let change = RepositoryChange(
            revision: revision,
            value: value,
            reason: .refresh
        )
        for continuation in continuations.values { continuation.yield(change) }
    }

    public func upsertHost(_ host: Host) throws {
        if let index = value.hosts.firstIndex(where: { $0.id == host.id }) {
            value.hosts[index] = host
        } else {
            value.hosts.append(host)
        }
        try publish(.mutation)
    }

    public func requestHostDeletion(_ hostID: Host.ID) throws {
        value.hosts.removeAll { $0.id == hostID }
        try publish(.mutation)
    }

    public func clearReferencesForDeletedHost(_ hostID: Host.ID) throws {}
    public func finalizeHostDeletion(_ hostID: Host.ID) throws {}

    private func publish(_ reason: RepositoryChangeReason) throws {
        revision &+= 1
        let change = RepositoryChange(revision: revision, value: value, reason: reason)
        for continuation in continuations.values { continuation.yield(change) }
    }
}

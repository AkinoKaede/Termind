import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct HostLibrarySnapshot: Equatable, Sendable {
    public var hosts: [Host]
    public var groups: [HostGroup]

    public static let empty = HostLibrarySnapshot(hosts: [], groups: [])
    public init(hosts: [Host], groups: [HostGroup]) {
        self.hosts = hosts
        self.groups = groups
    }

}

@MainActor
public protocol HostRepository: AnyObject {
    func snapshot() throws -> RepositoryChange<HostLibrarySnapshot>
    func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>>
    func refresh() throws
    func upsertHost(_ host: Host) throws
    func deletionImpact(for hostID: Host.ID) throws -> HostDeletionImpact
    func requestHostDeletion(_ hostID: Host.ID) throws
    func clearReferencesForDeletedHost(_ hostID: Host.ID) throws
    func finalizeHostDeletion(_ hostID: Host.ID) throws
}

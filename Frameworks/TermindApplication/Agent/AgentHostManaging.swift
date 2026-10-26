// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
public protocol AgentHostManaging: AnyObject {
    var hosts: [Host] { get }
    var groups: [HostGroup] { get }
    func saveHost(_ host: Host) async throws
    func saveGroup(_ group: HostGroup) throws
    func deleteHost(_ id: UUID) throws
    func deleteGroup(_ id: UUID, keepHosts: Bool) throws
}

/// Uses the same library and durable deletion workflow as the native editors.
@MainActor
public final class AgentHostLibrary: AgentHostManaging {
    private let library: HostLibraryModel
    public var requestDeletion: ((UUID) -> Bool)?

    public init(library: HostLibraryModel) { self.library = library }
    public var hosts: [Host] { library.hosts }
    public var groups: [HostGroup] { library.groups }

    public func saveHost(_ host: Host) async throws {
        let previous = library.host(host.id)
        try await library.resolveSavingHostsAccess([host], requestsUpgrade: false)
        try Task.checkCancellation()
        guard library.host(host.id) == previous, library.saveHost(host) else { throw MutationError.failed }
    }

    public func saveGroup(_ group: HostGroup) throws {
        guard library.saveGroup(group) else { throw MutationError.failed }
    }

    public func deleteHost(_ id: UUID) throws {
        guard let host = library.host(id), !host.isTailscaleManaged,
            requestDeletion?(id) == true
        else { throw MutationError.failed }
    }

    public func deleteGroup(_ id: UUID, keepHosts: Bool) throws {
        guard library.group(id) != nil else { throw MutationError.failed }
        if !keepHosts {
            for host in library.hosts(inTreeOf: id) where !host.isTailscaleManaged {
                try deleteHost(host.id)
            }
        }
        guard library.removeGroup(id) else { throw MutationError.failed }
    }

    private enum MutationError: Error { case failed }
}

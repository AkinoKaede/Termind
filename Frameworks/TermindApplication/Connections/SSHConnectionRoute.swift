// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

/// A session-owned route snapshot. Hosts and login hints contain no secrets and
/// do not become Vault records until an explicit save.
public nonisolated struct SSHConnectionRoute: Hashable, Sendable {
    public var hosts: [Host]
    public var usernames: [Host.ID: String]
    public var sourceHostIDs: [Host.ID: Host.ID]

    public init(
        hosts: [Host], usernames: [Host.ID: String] = [:], sourceHostIDs: [Host.ID: Host.ID] = [:]
    ) {
        self.hosts = hosts
        self.usernames = usernames
        self.sourceHostIDs = sourceHostIDs
    }

    public var isValid: Bool {
        guard !hosts.isEmpty, hosts.count <= 8, Set(hosts.map(\.id)).count == hosts.count else { return false }
        return hosts.enumerated().allSatisfy { index, host in
            host.jumpHostID == (index == 0 ? nil : hosts[index - 1].id)
        }
    }

    public func host(_ id: Host.ID) -> Host? { hosts.first { $0.id == id } }

    /// Login hints fill only unbound Hosts. An Identity still resolves its own
    /// credentials, and an interactive submission always takes precedence.
    public func submissions(
        merging submissions: [Host.ID: SSHAuthenticationSubmission]
    ) -> [Host.ID: SSHAuthenticationSubmission] {
        var result = submissions
        for host in hosts where host.identityID == nil && result[host.id] == nil {
            if let username = usernames[host.id] {
                result[host.id] = SSHAuthenticationSubmission(username: username)
            }
        }
        return result
    }

    public static var invalidRouteError: TermindSSHError {
        .route(String(localized: "The Jump Host route is invalid or exceeds eight hosts."))
    }
}

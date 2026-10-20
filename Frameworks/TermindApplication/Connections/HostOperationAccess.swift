// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

public typealias HostOperationAccessCheck = @Sendable () throws -> Void

/// Connection snapshots consult current access without retaining the main-actor library.
public nonisolated final class HostOperationAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = HostAccessPolicy(entitlement: .unrestrictedForTesting)
    private var hosts: [Host] = []

    public init() {}

    public func update(policy: HostAccessPolicy, hosts: [Host]) {
        lock.withLock {
            self.policy = policy
            self.hosts = hosts
        }
    }

    public func check(_ ids: [UUID]) throws {
        try lock.withLock {
            for id in ids { try policy.requireAccess(to: id, in: hosts) }
        }
    }
}

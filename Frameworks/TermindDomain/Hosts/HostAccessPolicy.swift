// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum HostAccessError: Error, Equatable, Sendable {
    case hostLimit
    case lockedHost(UUID)
    case verifyingEntitlement
    case entitlementVerificationFailed
}

/// Locks are derived, never synced. Historical undated records retain stable priority.
public nonisolated struct HostAccessPolicy: Sendable {
    public static let freeHostLimit = 3
    public var entitlement: EntitlementStatus

    public init(entitlement: EntitlementStatus) {
        self.entitlement = entitlement
    }

    public func unlockedIDs(in hosts: [Host]) -> Set<UUID> {
        let ordinary = hosts.filter { !$0.isTailscaleManaged }
        guard !entitlement.hasProAccess else { return Set(ordinary.map(\.id)) }
        return Set(
            ordinary.sorted {
                if $0.createdAt != $1.createdAt {
                    return ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast)
                }
                return $0.id.uuidString < $1.id.uuidString
            }.prefix(Self.freeHostLimit).map(\.id))
    }

    public func isLocked(_ id: UUID, in hosts: [Host]) -> Bool {
        guard entitlement != .loading, entitlement != .verificationFailed,
            hosts.contains(where: { $0.id == id && !$0.isTailscaleManaged })
        else { return false }
        return !unlockedIDs(in: hosts).contains(id)
    }

    public func requireAccess(to id: UUID, in hosts: [Host]) throws {
        guard hosts.contains(where: { $0.id == id && !$0.isTailscaleManaged }),
            !unlockedIDs(in: hosts).contains(id)
        else { return }
        try requireResolvedEntitlement()
        throw HostAccessError.lockedHost(id)
    }

    public func requireSaving(_ proposed: [Host], in hosts: [Host]) throws {
        guard !entitlement.hasProAccess else { return }
        let existing = Set(hosts.filter { !$0.isTailscaleManaged }.map(\.id))
        let additions = Set(proposed.filter { !$0.isTailscaleManaged }.map(\.id)).subtracting(existing)
        guard !additions.isEmpty, existing.count + additions.count > Self.freeHostLimit else { return }
        try requireResolvedEntitlement()
        throw HostAccessError.hostLimit
    }

    private func requireResolvedEntitlement() throws {
        if entitlement == .loading { throw HostAccessError.verifyingEntitlement }
        if entitlement == .verificationFailed { throw HostAccessError.entitlementVerificationFailed }
    }
}

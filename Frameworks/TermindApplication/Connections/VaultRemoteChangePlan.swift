// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Platform-neutral effects required after a remote Vault snapshot changes
/// connection-defining Host fields.
public nonisolated struct VaultRemoteChangePlan: Sendable {
    public nonisolated struct HostChange: Sendable {
        public let id: Host.ID
        public let isRemoved: Bool
        public let routeChanged: Bool
    }

    public let hosts: [HostChange]
    public let forwardingRuleIDs: [PortForwardingRule.ID]

    public static func make(
        currentHosts: [Host],
        snapshot: VaultSnapshot,
        changedKeys: Set<VaultRecordKey>
    ) -> VaultRemoteChangePlan {
        let current = Dictionary(uniqueKeysWithValues: currentHosts.map { ($0.id, $0) })
        let next = Dictionary(uniqueKeysWithValues: snapshot.hosts.map { ($0.id, $0) })
        let hosts = changedKeys.compactMap { key -> HostChange? in
            guard key.kind == .host, let old = current[key.id] else { return nil }
            let updated = next[key.id]
            return HostChange(
                id: key.id,
                isRemoved: updated == nil,
                routeChanged: updated.map { !old.hasSameConnectionRoute(as: $0) } ?? true
            )
        }
        return VaultRemoteChangePlan(
            hosts: hosts,
            forwardingRuleIDs: changedKeys.filter { $0.kind == .portForwarding }.map(\.id)
        )
    }
}

extension Host {
    public nonisolated func hasSameSSHConnectionRoute(as other: Host) -> Bool {
        host == other.host
            && sshEnabled == other.sshEnabled
            && sshPort == other.sshPort
            && sshIdentityID == other.sshIdentityID
            && sshCharset == other.sshCharset
            && jumpHostID == other.jumpHostID
            && proxy == other.proxy
    }

    public nonisolated func hasSameTelnetConnection(as other: Host) -> Bool {
        host == other.host
            && telnetEnabled == other.telnetEnabled
            && telnetPort == other.telnetPort
            && telnetIdentityID == other.telnetIdentityID
            && telnetCharset == other.telnetCharset
            && telnetProxy == other.telnetProxy
    }

    public nonisolated func hasSameConnectionRoute(as other: Host) -> Bool {
        hasSameSSHConnectionRoute(as: other)
    }
}

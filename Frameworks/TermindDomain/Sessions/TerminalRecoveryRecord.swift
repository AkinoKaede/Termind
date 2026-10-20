// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct TerminalRecoveryRecord: Codable, Identifiable, Sendable {
    public let id: UUID
    public let host: Host
    public let username: String
    public let transport: HostTerminalProtocol
    public let savedAt: Date

    public init(id: UUID, host: Host, username: String, transport: HostTerminalProtocol) {
        self.id = id
        var metadata = host
        // Environment values can contain secrets; recovery only needs connection identity.
        metadata.environmentVariables = []
        self.host = metadata
        self.username = username
        self.transport = transport
        savedAt = Date()
    }

    public func matches(_ current: Host) -> Bool {
        host.id == current.id && host.host == current.host && host.sshPort == current.sshPort
            && host.sshIdentityID == current.sshIdentityID && host.jumpHostID == current.jumpHostID
            && host.proxy == current.proxy && host.tailscale == current.tailscale
            && (transport != .eternalTerminal
                || host.terminalTransports.eternalTerminalPort == current.terminalTransports.eternalTerminalPort)
            && current.isEnabled(transport)
    }
}

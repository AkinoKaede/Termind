// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHRouteHopConfiguration: Sendable {
    public var id: Host.ID
    public var name: String
    public var host: String
    public var port: Int
    public var username: String
    public var credentials: [SSHCredentials]
    public var expectedHostKeys: Set<SSHHostKeyIdentity>
    public var proxy: SSHTransportProxy?
    public var authenticationReference: SSHAuthenticationReference
    public init(
        id: Host.ID, name: String, host: String, port: Int, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: SSHTransportProxy? = nil,
        authenticationReference: SSHAuthenticationReference? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.expectedHostKeys = expectedHostKeys
        self.proxy = proxy
        self.authenticationReference =
            authenticationReference
            ?? SSHAuthenticationReference(
                username: username,
                permitsNone: credentials.isEmpty,
                hasEphemeralSecret: !credentials.isEmpty
            )
    }

    public func clearSecrets() {
        for credential in credentials { credential.clearSecrets() }
        proxy?.clearSecret()
    }

}

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
    public init(
        id: Host.ID, name: String, host: String, port: Int, username: String, credentials: [SSHCredentials],
        expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: SSHTransportProxy? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.credentials = credentials
        self.expectedHostKeys = expectedHostKeys
        self.proxy = proxy
    }

}

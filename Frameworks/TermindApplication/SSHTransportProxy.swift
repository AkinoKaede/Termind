import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct SSHTransportProxy: Sendable {
    public var kind: HostProxy.ProtocolKind
    public var hostname: String
    public var port: Int
    public var username: String
    public var password: String?
    public var identityID: Identity.ID?
    public init(
        kind: HostProxy.ProtocolKind, hostname: String, port: Int, username: String,
        password: String? = nil, identityID: Identity.ID? = nil
    ) {
        self.kind = kind
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
        self.identityID = identityID
    }

}

import Foundation
import TermindDomain

import struct TermindDomain.Host

public nonisolated struct TerminalTransportProxy: Sendable {
    public var kind: HostProxy.ProtocolKind
    public var hostname: String
    public var port: Int
    public var username: String
    public var password: SSHSecret?
    public var identityID: Identity.ID?
    public var ownerHostID: Host.ID?
    public init(
        kind: HostProxy.ProtocolKind, hostname: String, port: Int, username: String,
        password: SSHSecret? = nil, identityID: Identity.ID? = nil, ownerHostID: Host.ID? = nil
    ) {
        self.kind = kind
        self.hostname = hostname
        self.port = port
        self.username = username
        self.password = password
        self.identityID = identityID
        self.ownerHostID = ownerHostID
    }

    public func clearSecret() { password?.clear() }

}

public typealias SSHTransportProxy = TerminalTransportProxy

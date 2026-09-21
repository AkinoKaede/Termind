import Foundation
import TermindDomain

import struct TermindDomain.Host

/// A reusable SSH route with no authentication material. Network topology is
/// frozen for the live session; credentials are resolved from Identity/Key IDs
/// immediately before each additional connection opens.
public nonisolated struct SSHAdditionalConnectionSnapshot: Equatable, Sendable {
    public struct Proxy: Equatable, Sendable {
        public var kind: HostProxy.ProtocolKind
        public var hostname: String
        public var port: Int
        public var username: String
        public var identityID: Identity.ID?

        public init(
            kind: HostProxy.ProtocolKind, hostname: String, port: Int,
            username: String = "", identityID: Identity.ID?
        ) {
            self.kind = kind
            self.hostname = hostname
            self.port = port
            self.username = username
            self.identityID = identityID
        }
    }

    public struct Node: Equatable, Sendable {
        public var id: Host.ID
        public var name: String
        public var host: String
        public var port: Int
        public var authentication: SSHAuthenticationReference
        public var expectedHostKeys: Set<SSHHostKeyIdentity>
        public var proxy: Proxy?
        public var charset: RemoteCharset

        public init(
            id: Host.ID, name: String, host: String, port: Int,
            authentication: SSHAuthenticationReference,
            expectedHostKeys: Set<SSHHostKeyIdentity>, proxy: Proxy?,
            charset: RemoteCharset = .utf8
        ) {
            self.id = id
            self.name = name
            self.host = host
            self.port = port
            self.authentication = authentication
            self.expectedHostKeys = expectedHostKeys
            self.proxy = proxy
            self.charset = charset
        }
    }

    public var target: Node
    public var jumps: [Node]

    public init(target: Node, jumps: [Node] = []) {
        self.target = target
        self.jumps = jumps
    }

    /// Drops all resolved authentication material while retaining the route's
    /// explicit Identity/Key provenance. Durable trust may be refreshed by the
    /// host store before this value is retained for additional connections.
    public init(configuration: SSHConnectionConfiguration) {
        func proxy(_ value: SSHTransportProxy?) -> Proxy? {
            value.map {
                Proxy(
                    kind: $0.kind, hostname: $0.hostname, port: $0.port,
                    username: $0.username,
                    identityID: $0.identityID
                )
            }
        }
        target = Node(
            id: configuration.hostID, name: configuration.host,
            host: configuration.host, port: configuration.port,
            authentication: configuration.authenticationReference,
            expectedHostKeys: configuration.expectedHostKeys,
            proxy: proxy(configuration.proxy), charset: configuration.charset
        )
        jumps = configuration.jumps.map {
            Node(
                id: $0.id, name: $0.name, host: $0.host, port: $0.port,
                authentication: $0.authenticationReference,
                expectedHostKeys: $0.expectedHostKeys, proxy: proxy($0.proxy)
            )
        }
    }

    public var hostID: Host.ID { target.id }
}

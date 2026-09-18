import Foundation
import TermindDomain

import struct TermindDomain.Host

/// The host, trust, and credential capabilities required to establish a live
/// SSH-backed session. Session features depend on this port instead of gaining
/// the complete Vault mutation surface from `HostLibraryModel`.
@MainActor
public protocol RemoteSessionHostStore: AnyObject, Sendable {
    func host(_ id: Host.ID) -> Host?
    func identity(_ id: Identity.ID) -> Identity?
    func identity(for host: Host) -> Identity?
    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef?
    func knownHosts(for host: Host) -> [KnownHostEntry]
    func route(for host: Host) -> [Host]
    func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> Set<SSHHostKeyIdentity>
    func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation
    func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration
    func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration]
    func transportProxy(for host: Host) throws -> SSHTransportProxy?
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution
    func passwordCredential(for identity: Identity) throws -> String?
    func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential?
    func recordIdentityCredentialAccess(_ identityIDs: Set<Identity.ID>, at date: Date)
    func setConnectionStatus(_ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID)
    func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID)
    func trust(_ entry: KnownHostEntry)
    func markKnownHostMismatched(hostname: String, port: Int)
    @discardableResult func upsert(_ identity: Identity) -> Bool
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws
    func upsert(_ host: Host)
}

extension RemoteSessionHostStore {
    /// Refresh only durable trust after a successful handshake. The connection may
    /// have prompted before its configuration was captured; once-only approval is
    /// deliberately not promoted into permission for additional connections.
    public func configurationForAdditionalConnection(
        from configuration: SSHConnectionConfiguration
    ) -> SSHConnectionConfiguration {
        func keys(id: UUID, hostname: String, port: Int) -> Set<SSHHostKeyIdentity> {
            Set(knownHosts(for: Host(id: id, name: hostname, host: hostname, port: port)).map(\.identity))
        }
        var result = configuration
        result.expectedHostKeys = keys(id: result.hostID, hostname: result.host, port: result.port)
        for index in result.jumps.indices {
            let hop = result.jumps[index]
            result.jumps[index].expectedHostKeys = keys(id: hop.id, hostname: hop.host, port: hop.port)
        }
        return result
    }

    public func connectionPasswordCredential(for identity: Identity) throws -> String? {
        let password = try passwordCredential(for: identity)
        if password != nil {
            recordIdentityCredentialAccess([identity.id], at: Date())
        }
        return password
    }

    public func connectionKeyCredential(
        for key: SSHKeyRef, identityID: Identity.ID?
    ) throws -> StoredSSHKeyCredential? {
        let credential = try keyCredential(for: key)
        if credential != nil, let identityID {
            recordIdentityCredentialAccess([identityID], at: Date())
        }
        return credential
    }

    public func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> Set<SSHHostKeyIdentity> {
        try expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionConfiguration {
        try sshConnectionConfiguration(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> [SSHRouteHopConfiguration] {
        try sshJumpConfigurations(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: .requireKnownHost
        )
    }

    public func prepareSSHConnection(
        for host: Host,
        submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionPreparation {
        var preparation = try prepareSSHConnection(for: host, submissions: submissions)
        for index in preparation.nodes.indices {
            if let key = temporaryHostKeys[preparation.nodes[index].host.id] {
                preparation.nodes[index].trustedKeys.insert(key)
            }
        }
        return preparation
    }
}

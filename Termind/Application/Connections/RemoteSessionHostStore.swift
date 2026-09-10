import Foundation

/// The host, trust, and credential capabilities required to establish a live
/// SSH-backed session. Session features depend on this port instead of gaining
/// the complete Vault mutation surface from `HostLibraryModel`.
@MainActor
protocol RemoteSessionHostStore: AnyObject, Sendable {
    func host(_ id: Host.ID) -> Host?
    func identity(_ id: Identity.ID) -> Identity?
    func identity(for host: Host) -> Identity?
    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef?
    func knownHosts(for host: Host) -> [KnownHostEntry]
    func route(for host: Host) -> [Host]
    func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> Set<SSHHostKeyIdentity>
    func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation
    func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> SSHConnectionConfiguration
    func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity]
    ) throws -> [SSHRouteHopConfiguration]
    func transportProxy(for host: Host) throws -> SSHTransportProxy?
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution
    func passwordCredential(for identity: Identity) throws -> String?
    func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential?
    func setConnectionStatus(_ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID)
    func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID)
    func trust(_ entry: KnownHostEntry)
    func markKnownHostMismatched(hostname: String, port: Int)
    @discardableResult func upsert(_ identity: Identity) -> Bool
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws
    func upsert(_ host: Host)
}

extension HostLibraryModel: RemoteSessionHostStore {}

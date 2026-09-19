import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// Saved-vault access exposed to transfer presentation and session entry points.
@Observable
final class TransferLibraryModel {
    private let library: HostLibraryModel

    init(library: HostLibraryModel) {
        self.library = library
    }
}

extension TransferLibraryModel: RemoteSessionHostStore {
    func host(_ id: Host.ID) -> Host? { library.host(id) }
    func identity(_ id: Identity.ID) -> Identity? { library.identity(id) }
    func identity(for host: Host) -> Identity? { library.identity(for: host) }
    func key(_ id: SSHKeyRef.ID) -> SSHKeyRef? { library.key(id) }
    func knownHosts(for host: Host) -> [KnownHostEntry] { library.knownHosts(for: host) }
    func route(for host: Host) -> [Host] { library.route(for: host) }
    func expectedHostKeys(
        for host: Host, temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> Set<SSHHostKeyIdentity> {
        try library.expectedHostKeys(
            for: host, temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
    }
    func prepareSSHConnection(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
        try library.prepareSSHConnection(for: host, submissions: submissions)
    }
    func sshConnectionConfiguration(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> SSHConnectionConfiguration {
        try library.sshConnectionConfiguration(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
    }
    func sshJumpConfigurations(
        for host: Host, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity],
        trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration] {
        try library.sshJumpConfigurations(
            for: host, submissions: submissions,
            temporaryHostKeys: temporaryHostKeys,
            trustPolicy: trustPolicy
        )
    }
    func prepareSSHConnection(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission]
    ) throws -> SSHConnectionPreparation {
        try library.prepareSSHConnection(for: route, submissions: submissions)
    }
    func sshJumpConfigurations(
        for route: SSHConnectionRoute, submissions: [Host.ID: SSHAuthenticationSubmission],
        temporaryHostKeys: [Host.ID: SSHHostKeyIdentity], trustPolicy: SSHHostTrustPolicy
    ) throws -> [SSHRouteHopConfiguration] {
        try library.sshJumpConfigurations(
            for: route, submissions: submissions, temporaryHostKeys: temporaryHostKeys, trustPolicy: trustPolicy
        )
    }
    func saveConnectionRoute(
        _ route: SSHConnectionRoute, authentication: SSHAuthenticationSubmission?,
        authenticationHostID: Host.ID?, suppliedPassword: String?
    ) throws -> SSHConnectionRoute {
        try library.saveConnectionRoute(
            route, authentication: authentication, authenticationHostID: authenticationHostID,
            suppliedPassword: suppliedPassword
        )
    }
    func transportProxy(for host: Host) throws -> SSHTransportProxy? {
        try library.transportProxy(for: host)
    }
    func sshCredentials(for identity: Identity) -> SSHCredentialResolution {
        library.sshCredentials(for: identity)
    }
    func passwordCredential(for identity: Identity) throws -> String? {
        try library.passwordCredential(for: identity)
    }
    func keyCredential(for key: SSHKeyRef) throws -> StoredSSHKeyCredential? {
        try library.keyCredential(for: key)
    }
    func recordIdentityCredentialAccess(_ identityIDs: Set<Identity.ID>, at date: Date) {
        library.recordIdentityCredentialAccess(identityIDs, at: date)
    }
    func setConnectionStatus(
        _ status: ConnectionStatus, connectionID: UUID, hostID: Host.ID
    ) {
        library.setConnectionStatus(status, connectionID: connectionID, hostID: hostID)
    }
    func recordRemoteSystemInfo(_ systemInfo: RemoteSystemInfo?, for hostID: Host.ID) {
        library.recordRemoteSystemInfo(systemInfo, for: hostID)
    }
    func trust(_ entry: KnownHostEntry) { library.trust(entry) }
    func markKnownHostMismatched(hostname: String, port: Int) {
        library.markKnownHostMismatched(hostname: hostname, port: port)
    }
    @discardableResult func upsert(_ identity: Identity) -> Bool { library.upsert(identity) }
    func upsert(_ identity: Identity, passwordUpdate: IdentityPasswordUpdate) throws {
        try library.upsert(identity, passwordUpdate: passwordUpdate)
    }
    func upsert(_ host: Host) { library.upsert(host) }
}

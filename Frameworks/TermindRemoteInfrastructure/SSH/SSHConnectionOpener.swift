import Foundation
import Logging
import TermindApplication
import TermindDomain

/// Connection-scoped entry point for socket routing, SSH handshake, host-key
/// verification, and authentication. Terminal, exec, SFTP, and forwarding
/// owners all use this boundary before opening their own Channels.
public nonisolated enum SSHConnectionOpener {
    public static func openAuthenticatedConnection(
        using configuration: SSHConnectionConfiguration,
        timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) throws -> SSHAuthenticatedConnection {
        try SSHPTYChannelWorker.openAuthenticatedConnection(
            using: configuration, timeout: timeout, progress: progress, logger: logger)
    }

    public static func openAuthenticatedConnection(
        using request: SSHConnectionRequest,
        timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.ssh-authentication")
    ) async throws -> SSHAuthenticatedConnection {
        try await SSHPTYChannelWorker.openAuthenticatedConnection(
            using: request, timeout: timeout, progress: progress, logger: logger)
    }

    public static func installAuthorizedKey(
        _ publicKey: String, named keyName: String, using request: SSHConnectionRequest,
        logger: Logger = ApplicationLogger.disabled("termind.ssh-key-install"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) async throws {
        try await SSHPTYChannelWorker.installAuthorizedKey(
            publicKey, named: keyName, using: request, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }

    public static func authorizedKeyInstallInput(publicKey: String, keyName: String) throws -> Data {
        try SSHPTYChannelWorker.authorizedKeyInstallInput(
            publicKey: publicKey, keyName: keyName)
    }

    public static func authenticate(
        username: String, credentials: [SSHCredentials], libssh2Session: OpaquePointer,
        keyboardInteractive: SSHKeyboardInteractiveExchange? = nil, socket: Int32 = -1
    ) throws -> String {
        try SSHPTYChannelWorker.authenticate(
            username: username, credentials: credentials, session: libssh2Session,
            keyboardInteractive: keyboardInteractive, socket: socket)
    }

    public static func authenticate(
        username: String, credentials: [SSHCredentials], libssh2Session: OpaquePointer,
        afterHostKeyApproval: Bool,
        keyboardInteractive: SSHKeyboardInteractiveExchange? = nil, socket: Int32 = -1
    ) throws -> String {
        try SSHPTYChannelWorker.authenticate(
            username: username, credentials: credentials, session: libssh2Session,
            afterHostKeyApproval: afterHostKeyApproval,
            keyboardInteractive: keyboardInteractive, socket: socket)
    }

    public static func observation(
        host: String, port: Int, libssh2Session: OpaquePointer
    ) throws -> SSHHostKeyObservation {
        try SSHPTYChannelWorker.observation(
            host: host, port: port, session: libssh2Session)
    }

    public static func validateHostKey(
        _ observed: SSHHostKeyObservation, expected: Set<SSHHostKeyIdentity>
    ) throws {
        try SSHPTYChannelWorker.validateHostKey(observed, expected: expected)
    }

    public static func authorizeHostKey(
        hostID: TermindDomain.Host.ID, observed: SSHHostKeyObservation,
        expected: Set<SSHHostKeyIdentity>, authorizer: SSHHostKeyAuthorizer?
    ) async throws {
        try await SSHPTYChannelWorker.authorizeHostKey(
            hostID: hostID, observed: observed, expected: expected, authorizer: authorizer)
    }

    public static func performHandshake(
        _ libssh2Session: OpaquePointer, socket: Int32,
        peer: String, timeout: TimeInterval = 20
    ) throws {
        try SSHPTYChannelWorker.performHandshake(
            libssh2Session, socket: socket, peer: peer, timeout: timeout)
    }

    public static func connectionError(
        _ libssh2Session: OpaquePointer, prefix: String
    ) -> TermindSSHError {
        SSHPTYChannelWorker.connectionError(libssh2Session, prefix: prefix)
    }
}

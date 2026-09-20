import Foundation
import Logging
import TermindApplication
import TermindDomain

/// Application-owned construction and one-shot operation boundary for all
/// SSH/SFTP transports. Features receive this service instead of constructing
/// infrastructure clients in views.
public nonisolated final class RemoteConnectionCoordinator: Sendable {
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private let maxSessionsPolicy: SSHMaxSessionsPolicy
    let logger: Logger

    public init(
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.remote-connection"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) {
        self.keyboardInteractive = keyboardInteractive
        self.logger = logger
        self.maxSessionsPolicy = maxSessionsPolicy
    }

    public func updateSSHPreferences(_ preferences: SSHPreferences) {
        maxSessionsPolicy.update(preferences)
    }

    public func withKeyboardInteractive(_ handler: @escaping SSHKeyboardInteractiveHandler)
        -> RemoteConnectionCoordinator
    {
        RemoteConnectionCoordinator(
            keyboardInteractive: handler, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }
    public func makePTYChannel(
        output: @escaping SSHPTYChannel.OutputHandler,
        exit: @escaping SSHPTYChannel.ExitHandler,
        shellIntegration: @escaping SSHPTYChannel.ShellIntegrationHandler = { _ in }
    ) -> SSHPTYChannel {
        SSHPTYChannel(
            output: output, exit: exit, shellIntegration: shellIntegration, keyboardInteractive: keyboardInteractive,
            logger: logger, maxSessionsPolicy: maxSessionsPolicy
        )
    }

    public func makeSFTPClient() -> any SFTPClientProtocol {
        SFTPClient(
            keyboardInteractive: keyboardInteractive, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }

    public func makeConnection() -> any SSHConnectionProtocol {
        SSHConnection(
            keyboardInteractive: keyboardInteractive, logger: logger,
            maxSessionsPolicy: maxSessionsPolicy)
    }

    /// Mirrors `connectSFTP`, including its guarantee that a session which fails
    /// to come up is torn down here rather than handed back half-open.
    public func connectConnection(
        using configuration: SSHConnectionConfiguration
    ) async throws -> any SSHConnectionProtocol {
        try await connectConnection(
            using: SSHConnectionRequest(configuration: configuration)
        )
    }

    public func connectConnection(
        using request: SSHConnectionRequest
    ) async throws -> any SSHConnectionProtocol {
        let connection = makeConnection()
        do {
            try await connection.connect(using: request)
            return connection
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    public func connectSFTP(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler? = nil,
        connectionFailure: (@Sendable (String) -> Void)? = nil
    ) async throws -> any SFTPClientProtocol {
        try await connectSFTP(
            using: SSHConnectionRequest(configuration: configuration),
            progress: progress, connectionFailure: connectionFailure
        )
    }

    public func connectSFTP(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler? = nil,
        connectionFailure: (@Sendable (String) -> Void)? = nil
    ) async throws -> any SFTPClientProtocol {
        let client = makeSFTPClient()
        do {
            try await client.connect(
                using: request, progress: progress,
                connectionFailure: connectionFailure
            )
            return client
        } catch {
            await client.disconnect()
            throw error
        }
    }

    public func installAuthorizedKey(
        _ publicKey: String, named keyName: String,
        using configuration: SSHConnectionConfiguration
    ) async throws {
        try await SSHPTYChannel.installAuthorizedKey(
            publicKey, named: keyName,
            using: SSHConnectionRequest(configuration: configuration, keyboardInteractive: keyboardInteractive),
            logger: logger, maxSessionsPolicy: maxSessionsPolicy
        )
    }
}

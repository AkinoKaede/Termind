import Foundation
import Logging
import TermindApplication
import TermindDomain

/// Application-owned construction and one-shot operation boundary for all
/// SSH/SFTP transports. Features receive this service instead of constructing
/// infrastructure clients in views.
public nonisolated final class RemoteConnectionCoordinator: Sendable {
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    let logger: Logger

    public init(
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.remote-connection")
    ) {
        self.keyboardInteractive = keyboardInteractive
        self.logger = logger
    }

    public func withKeyboardInteractive(_ handler: @escaping SSHKeyboardInteractiveHandler)
        -> RemoteConnectionCoordinator
    {
        RemoteConnectionCoordinator(keyboardInteractive: handler, logger: logger)
    }
    public func makeSSHSession(
        output: @escaping SSHSessionActor.OutputHandler,
        exit: @escaping SSHSessionActor.ExitHandler,
        shellIntegration: @escaping SSHSessionActor.ShellIntegrationHandler = { _ in }
    ) -> SSHSessionActor {
        SSHSessionActor(
            output: output, exit: exit, shellIntegration: shellIntegration, keyboardInteractive: keyboardInteractive,
            logger: logger
        )
    }

    public func makeSFTPClient() -> any SFTPClientProtocol {
        SFTPClient(keyboardInteractive: keyboardInteractive, logger: logger)
    }

    public func makeExecSession() -> any SSHExecSessionProtocol {
        SSHExecSession(keyboardInteractive: keyboardInteractive, logger: logger)
    }

    /// Mirrors `connectSFTP`, including its guarantee that a session which fails
    /// to come up is torn down here rather than handed back half-open.
    public func connectExec(
        using configuration: SSHConnectionConfiguration
    ) async throws -> any SSHExecSessionProtocol {
        try await connectExec(
            using: SSHConnectionRequest(configuration: configuration)
        )
    }

    public func connectExec(
        using request: SSHConnectionRequest
    ) async throws -> any SSHExecSessionProtocol {
        let session = makeExecSession()
        do {
            try await session.connect(using: request)
            return session
        } catch {
            await session.disconnect()
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
        try await SSHSessionActor.installAuthorizedKey(
            publicKey, named: keyName,
            using: SSHConnectionRequest(configuration: configuration, keyboardInteractive: keyboardInteractive),
            logger: logger
        )
    }
}

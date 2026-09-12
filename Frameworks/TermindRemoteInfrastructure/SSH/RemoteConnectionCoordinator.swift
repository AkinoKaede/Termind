import Foundation
import TermindApplication
import TermindDomain

/// Application-owned construction and one-shot operation boundary for all
/// SSH/SFTP transports. Features receive this service instead of constructing
/// infrastructure clients in views.
public nonisolated final class RemoteConnectionCoordinator: Sendable {
    public init() {}
    public func makeSSHSession(
        output: @escaping SSHSessionActor.OutputHandler,
        exit: @escaping SSHSessionActor.ExitHandler,
        shellIntegration: @escaping SSHSessionActor.ShellIntegrationHandler = { _ in }
    ) -> SSHSessionActor {
        SSHSessionActor(
            output: output, exit: exit, shellIntegration: shellIntegration
        )
    }

    public func makeSFTPClient() -> any SFTPClientProtocol { SFTPClient() }

    public func makeExecSession() -> any SSHExecSessionProtocol { SSHExecSession() }

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
            publicKey, named: keyName, using: configuration
        )
    }
}

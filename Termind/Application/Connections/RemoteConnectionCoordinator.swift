import Foundation

/// Application-owned construction and one-shot operation boundary for all
/// SSH/SFTP transports. Features receive this service instead of constructing
/// infrastructure clients in views.
nonisolated final class RemoteConnectionCoordinator: Sendable {
    func makeSSHSession(
        output: @escaping SSHSessionActor.OutputHandler,
        exit: @escaping SSHSessionActor.ExitHandler
    ) -> SSHSessionActor {
        SSHSessionActor(output: output, exit: exit)
    }

    func makeSFTPClient() -> any SFTPClientProtocol { SFTPClient() }

    func connectSFTP(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler? = nil
    ) async throws -> any SFTPClientProtocol {
        let client = makeSFTPClient()
        do {
            try await client.connect(using: configuration, progress: progress)
            return client
        } catch {
            await client.disconnect()
            throw error
        }
    }

    func installAuthorizedKey(
        _ publicKey: String, using configuration: SSHConnectionConfiguration
    ) async throws {
        try await SSHSessionActor.installAuthorizedKey(publicKey, using: configuration)
    }
}

import Foundation
import TermindApplication
import TermindDomain

@MainActor
public struct RemoteSessionTerminator {
    private var connect: (SSHConnectionRequest) async throws -> any SSHConnectionProtocol
    private var backends: RemoteSessionBackendRegistry

    public init(
        connect: @escaping (SSHConnectionRequest) async throws -> any SSHConnectionProtocol,
        backends: RemoteSessionBackendRegistry = .live
    ) {
        self.connect = connect
        self.backends = backends
    }

    public static func live(coordinator: RemoteConnectionCoordinator) -> Self {
        Self(connect: { try await coordinator.connectConnection(using: $0) })
    }

    public func terminate(_ close: RemoteSessionCloseRequest, hosts: any RemoteSessionHostStore) async throws {
        let reference = close.reference
        guard reference.isManaged else { return }
        if let existing = close.connection {
            let prepared: (any RemoteSessionBackend)?
            do {
                let backend = try backends.backend(reference.backend, execute: await existing.executor())
                try await validate(backend, reference: reference)
                prepared = backend
            } catch {
                await existing.disconnect()
                // Only connection/preflight failure may fall back. Never retry a termination command.
                try Task.checkCancellation()
                if let failure = error as? RemoteSessionFailure, failure != .timedOut { throw error }
                prepared = nil
            }
            if let prepared {
                do {
                    try Task.checkCancellation()
                    try await prepared.terminate(reference)
                    await existing.disconnect()
                    return
                } catch {
                    await existing.disconnect()
                    throw error
                }
            }
        }
        var request = try hosts.additionalConnectionRequest(from: close.snapshot)
        defer { request.configuration.clearSecrets() }
        // Explicit close must not wake a sleeping host, forward an agent, or request user interaction.
        request.configuration.beforeConnect = nil
        request.permitsAgentForwarding = false
        guard request.configuration.hostID == reference.hostID,
            "\(request.configuration.host):\(request.configuration.port)" == reference.endpoint,
            request.configuration.username == reference.username
        else { throw RemoteSessionFailure.ownershipMismatch }
        try Task.checkCancellation()
        let connection = try await connect(request)
        do {
            try Task.checkCancellation()
            let backend = try backends.backend(reference.backend) { command in
                let result = try await connection.execute(
                    command, workingDirectory: nil, stdin: nil, timeout: 5,
                    outputLimit: 1024 * 1024, onOutput: nil)
                return RemoteSessionCommandResult(
                    stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode,
                    truncated: result.stdoutTruncated || result.stderrTruncated)
            }
            try await validate(backend, reference: reference)
            // Backends recheck identity and the ownership token in the remote termination command.
            try await backend.terminate(reference)
            await connection.disconnect()
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    private func validate(_ backend: any RemoteSessionBackend, reference: RemoteSessionReference) async throws {
        try Task.checkCancellation()
        try backend.validate(reference)
        let sessions = try await backend.sessions()
        try Task.checkCancellation()
        guard sessions.contains(where: { backend.matches(reference, session: $0) }) else {
            throw RemoteSessionFailure.ownershipMismatch
        }
    }
}

extension RemoteSessionCloseConnection {
    public init(channel: SSHPTYChannel) {
        self.init(
            prepare: {
                try await channel.releaseTerminalForControl()
                return try await channel.sessionCommandExecutor()
            },
            release: { await channel.disconnect() })
    }
}

import Foundation
import TermindApplication
import TermindDomain

public nonisolated enum TerminalTransportRoute {
    public static func execute(_ command: String, using request: SSHConnectionRequest) async throws
        -> RemoteSessionCommandResult
    {
        defer { request.configuration.clearSecrets() }
        let connection = SSHConnection()
        do {
            try await connection.connect(using: request)
            let result = try await execute(command, on: connection)
            await connection.disconnect()
            return result
        } catch {
            await connection.disconnect()
            throw error
        }
    }

    static func execute(_ command: String, on connection: SSHConnection) async throws -> RemoteSessionCommandResult {
        let result = try await connection.execute(
            command, workingDirectory: nil, stdin: nil, timeout: 20, outputLimit: 262_144, onOutput: nil)
        return RemoteSessionCommandResult(
            stdout: result.stdout, stderr: result.stderr, exitCode: result.exitCode,
            truncated: result.stdoutTruncated || result.stderrTruncated)
    }

    public static func open(using request: SSHConnectionRequest, port: Int) async throws -> SSHRoutedSocket {
        defer { request.configuration.clearSecrets() }
        try Task.checkCancellation()
        try request.configuration.accessCheck?()
        await request.configuration.beforeConnect?()
        try Task.checkCancellation()
        let config = request.configuration
        return try await SSHRoutedSocket.open(
            host: config.host, port: port, proxy: config.proxy, jumps: config.jumps, timeout: 20,
            authorizeHostKey: request.authorizeHostKey, network: config.network,
            keyboardInteractive: request.keyboardInteractive, securityKeySigning: request.securityKeySigning,
            interactionPolicy: request.interactionPolicy, hostKeyConstraints: request.hostKeyConstraints)
    }
}

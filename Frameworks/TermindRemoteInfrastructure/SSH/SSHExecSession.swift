import Foundation
import Logging
import TermindApplication

public nonisolated struct SSHExecResult: Hashable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public var signal: String?
    public var stdoutTruncated: Bool
    public var stderrTruncated: Bool

    public init(
        stdout: String, stderr: String, exitCode: Int32, signal: String? = nil,
        stdoutTruncated: Bool, stderrTruncated: Bool
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.signal = signal
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

/// The one failure that is safe to retry on a replacement transport. It is
/// emitted only before the remote process has started.
public nonisolated enum SSHExecSessionError: LocalizedError, Sendable {
    case transportUnavailable(any Error)
    case channelUnavailable(any Error)

    public var errorDescription: String? {
        switch self {
        case .transportUnavailable(let underlying): underlying.localizedDescription
        case .channelUnavailable(let underlying): underlying.localizedDescription
        }
    }
}

/// A long-lived authenticated transport that opens a private non-PTY Channel
/// for every command. Concurrent calls share the transport and are advanced by
/// one fair libssh2 owner; shell state and working directories never leak.
public nonisolated protocol SSHExecSessionProtocol: AnyObject, Sendable {
    func connect(using configuration: SSHConnectionConfiguration) async throws
    func connect(using request: SSHConnectionRequest) async throws
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult
    func disconnect() async
}

nonisolated extension SSHExecSessionProtocol {
    public func connect(using request: SSHConnectionRequest) async throws {
        try await connect(using: request.configuration)
    }
}

/// Called on the connection's serial libssh2 owner. It must return promptly.
public typealias SSHExecOutputHandler = @Sendable (Data, Bool) -> Void

public actor SSHExecSession: SSHExecSessionProtocol {
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private nonisolated let worker: SSHMultiplexedExecWorker

    public init(
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.ssh-exec")
    ) {
        self.keyboardInteractive = keyboardInteractive
        worker = SSHMultiplexedExecWorker(logger: logger)
    }

    public func connect(using configuration: SSHConnectionConfiguration) async throws {
        try await connect(using: SSHConnectionRequest(configuration: configuration))
    }

    public func connect(using request: SSHConnectionRequest) async throws {
        try await worker.connect(using: request.withKeyboardInteractiveFallback(keyboardInteractive))
    }

    public func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        let cancellation = TransferCancellationToken()
        return try await withTaskCancellationHandler {
            try await worker.execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit, cancellation: cancellation,
                onOutput: onOutput)
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func disconnect() async { await worker.disconnect() }
}

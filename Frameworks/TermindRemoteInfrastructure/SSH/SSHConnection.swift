import AgentKit
import Foundation
import Logging
import TermindApplication
import TermindDomain

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

public nonisolated enum SSHCommandInput: Sendable {
    /// Byte-transparent input. Charset conversion is intentionally bypassed.
    case plain(Data)
    /// Text encoded strictly with the connected Host's Charset.
    case text(String)
    /// UTF-8 secret text converted without materializing a Swift String.
    case secret(AgentSecret)

    func append(to queue: SSHByteQueue, charset: RemoteCharset = .utf8) throws {
        switch self {
        case .plain(var bytes):
            if !bytes.isEmpty, bytes.last != 0x0A { bytes.append(0x0A) }
            queue.append(bytes)
        case .text(let value):
            var bytes = try RemoteCharsetStreamConverter.encode(value, charset: charset)
            defer { bytes.resetBytes(in: bytes.indices) }
            if !bytes.isEmpty, bytes.last != 0x0A { bytes.append(0x0A) }
            queue.append(bytes)
        case .secret(let secret):
            defer { secret.clear() }
            try secret.withUnsafeBytes { bytes in
                let converter = try RemoteCharsetStreamConverter(charset: charset, direction: .encoding)
                var source = Data(bytes)
                defer { source.resetBytes(in: source.indices) }
                var converted = try converter.convert(source).data
                defer { converted.resetBytes(in: converted.indices) }
                converted.append(try converter.finish().data)
                queue.append(converted)
                if !converted.isEmpty, converted.last != 0x0A {
                    queue.append(contentsOf: [0x0A])
                }
            }
        }
    }
}

/// The one failure that is safe to retry on a replacement connection. It is
/// emitted only before the remote process has started.
public nonisolated enum SSHCommandExecutionError: LocalizedError, Sendable {
    case connectionUnavailable(any Error)
    case channelUnavailable(any Error)

    public var errorDescription: String? {
        switch self {
        case .connectionUnavailable(let underlying): underlying.localizedDescription
        case .channelUnavailable(let underlying): underlying.localizedDescription
        }
    }
}

/// A long-lived authenticated SSH connection that multiplexes non-PTY exec and
/// SFTP subsystem Channels through one fair libssh2 owner. Every command uses
/// a private exec Channel, so shell state and working directories never leak.
public nonisolated protocol SSHConnectionProtocol: AnyObject, Sendable {
    func connect(using configuration: SSHConnectionConfiguration) async throws
    func connect(using request: SSHConnectionRequest) async throws
    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult
    func openSFTPChannel() async throws -> any SFTPChannelProtocol
    func disconnect() async
}

nonisolated extension SSHConnectionProtocol {
    public func connect(using request: SSHConnectionRequest) async throws {
        defer { request.configuration.clearSecrets() }
        try await connect(using: request.configuration)
    }
}

/// Called on the connection's serial libssh2 owner with valid UTF-8 output. It must return promptly.
public typealias SSHExecOutputHandler = @Sendable (Data, Bool) -> Void

public actor SSHConnection: SSHConnectionProtocol {
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private nonisolated let worker: SSHConnectionWorker

    public init(
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.ssh-connection"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) {
        self.keyboardInteractive = keyboardInteractive
        worker = SSHConnectionWorker(logger: logger, maxSessionsPolicy: maxSessionsPolicy)
    }

    public func connect(using configuration: SSHConnectionConfiguration) async throws {
        try await connect(using: SSHConnectionRequest(configuration: configuration))
    }

    public func connect(using request: SSHConnectionRequest) async throws {
        try await connect(using: request, progress: nil, connectionFailure: nil)
    }

    public func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        defer { request.configuration.clearSecrets() }
        try await worker.connect(
            using: request.withKeyboardInteractiveFallback(keyboardInteractive),
            progress: progress, connectionFailure: connectionFailure)
    }

    public func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?,
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

    public func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        try await worker.openSFTPChannel()
    }

    public func disconnect() async { await worker.disconnect() }
}

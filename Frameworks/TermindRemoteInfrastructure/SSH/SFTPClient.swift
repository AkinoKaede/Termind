import AgentKit
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

public nonisolated final class TransferCancellationToken: @unchecked Sendable {
    public init() {}
    private let lock = NSLock()
    private var cancelled = false
    private var observers: [UUID: @Sendable () -> Void] = [:]

    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        let callbacks = lock.withLock {
            cancelled = true
            let callbacks = Array(observers.values)
            observers.removeAll()
            return callbacks
        }
        for callback in callbacks { callback() }
    }

    public func observeCancellation(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock {
            if cancelled { return true }
            observers[id] = callback
            return false
        }
        if alreadyCancelled { callback() }
        return id
    }

    public func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
}

public nonisolated struct SFTPProgress: Sendable {
    public var completedBytes: Int64
    public var totalBytes: Int64
    public var bytesPerSecond: Int64
    public init(completedBytes: Int64, totalBytes: Int64, bytesPerSecond: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
    }

}

nonisolated private struct SFTPProgressMeter {
    public let total: Int64
    public let report: @Sendable (SFTPProgress) -> Void
    public private(set) var completed: Int64 = 0
    private var sampledBytes: Int64 = 0
    private var sampledAt = ContinuousClock.now

    public nonisolated init(
        total: Int64, offset: Int64 = 0, report: @escaping @Sendable (SFTPProgress) -> Void
    ) {
        self.total = total
        self.completed = offset
        self.report = report
    }

    public nonisolated mutating func add(_ bytes: Int) {
        completed += Int64(bytes)
        sampledBytes += Int64(bytes)
        let elapsed = sampledAt.duration(to: .now)
        guard elapsed >= .milliseconds(250) else { return }
        let components = elapsed.components
        let seconds = max(
            0.001,
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
        report(
            SFTPProgress(
                completedBytes: completed, totalBytes: total,
                bytesPerSecond: Int64(Double(sampledBytes) / seconds)
            ))
        sampledBytes = 0
        sampledAt = .now
    }

    public nonisolated func finish() {
        report(
            SFTPProgress(
                completedBytes: completed, totalBytes: total, bytesPerSecond: 0
            ))
    }
}

/// One initialized SFTP subsystem running over an SSH channel.
public nonisolated protocol SFTPChannelProtocol: RemoteFileSystem, Sendable {
    /// Opens another SFTP subsystem channel on the same authenticated SSH
    /// connection. Connection-preferred schedulers use this only after a silent
    /// additional connection cannot be established.
    func openSiblingChannel() async throws -> any SFTPChannelProtocol
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
    func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws

    func openDownloadStream(
        at path: String, maximumBytes: Int64, cancellation: TransferCancellationToken
    ) async throws -> any SFTPDownloadStream
    func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage
    func disconnect() async
    func homeDirectory() async throws -> String
    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
    func copyFile(
        from sourcePath: String,
        to destinationPath: String,
        on destination: any SFTPChannelProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
    func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws
}

/// A connection-opening facade that creates and owns its primary SFTP channel.
public nonisolated protocol SFTPClientProtocol: SFTPChannelProtocol {
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?
    ) async throws
    func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws
    func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws
}

nonisolated extension SFTPChannelProtocol {
    public func openSiblingChannel() async throws -> any SFTPChannelProtocol {
        throw SFTPError.notConnected
    }
    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        guard resume.snapshot.editPolicy == nil else { throw SFTPEditFailure.unsupported }
        guard resume.snapshot.offset == 0 else { throw SFTPResumeFailure.unsupported }
        try await uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }
    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        guard resume.snapshot.offset == 0 else { throw SFTPResumeFailure.unsupported }
        try await downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }
    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        guard resume.snapshot.offset == 0 else { throw SFTPResumeFailure.unsupported }
        try await uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount, overwrite: overwrite,
            cancellation: cancellation, progress: progress, sourceSucceeded: sourceSucceeded)
    }

    public func openDownloadStream(
        at path: String, maximumBytes: Int64, cancellation: TransferCancellationToken
    ) async throws -> any SFTPDownloadStream {
        throw SFTPError.operation("This SFTP client does not support streamed downloads.")
    }
    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        throw SFTPError.operation("This SFTP client does not support streamed uploads.")
    }
    public func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage {
        let data = try await readFile(at: path, maximumBytes: AgentScratchWorkspace.Limits.fileBytes)
        var reader = try AgentTextPageReader(offset: offset, limit: limit)
        try reader.append(data)
        return try reader.finish()
    }

    public func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        throw SFTPError.operation("This SFTP client does not support inline reads.")
    }

    public func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        throw SFTPError.operation("This SFTP client does not support inline writes.")
    }

    public func copyFile(
        from sourcePath: String,
        to destinationPath: String,
        on destination: any SFTPChannelProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        throw SFTPError.operation("This SFTP client does not support streamed remote copying.")
    }
}

nonisolated extension SFTPClientProtocol {
    public func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        try await connect(
            using: request.configuration, progress: progress,
            connectionFailure: connectionFailure
        )
    }

    public func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        try await connect(using: configuration, progress: progress)
    }
}

public nonisolated enum SFTPError: LocalizedError, Sendable {
    case notConnected
    case connectionLost(String)
    case cancelled
    case localFile(String)
    case operation(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: String(localized: "The SFTP connection is not available.")
        case .connectionLost(let message): message
        case .cancelled: String(localized: "Transfer cancelled.")
        case .localFile(let message), .operation(let message): message
        }
    }
}

/// A failed transfer can leave its temporary remote file when cleanup also fails.
public nonisolated struct SFTPTemporaryFileCleanupError: LocalizedError, Sendable {
    public var errorDescription: String? { "\(cause.localizedDescription) (\(path))" }
    public let path: String
    public let cause: any Error
    public init(path: String, cause: any Error) {
        self.path = path
        self.cause = cause
    }
}

public actor SFTPClient: SFTPClientProtocol {
    private let keyboardInteractive: SSHKeyboardInteractiveHandler?
    private let logger: Logger
    private let maxSessionsPolicy: SSHMaxSessionsPolicy
    private var generation: UInt64 = 0
    private var connection: SSHConnection?
    private var channel: (any SFTPChannelProtocol)?

    public init(
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        logger: Logger = ApplicationLogger.disabled("termind.sftp"),
        maxSessionsPolicy: SSHMaxSessionsPolicy = SSHMaxSessionsPolicy()
    ) {
        self.keyboardInteractive = keyboardInteractive
        self.logger = logger
        self.maxSessionsPolicy = maxSessionsPolicy
    }

    deinit {
        let connection = connection
        let channel = channel
        Task {
            await channel?.disconnect()
            await connection?.disconnect()
        }
    }

    public func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler? = nil
    ) async throws {
        try await connect(
            using: SSHConnectionRequest(
                configuration: configuration,
                keyboardInteractive: keyboardInteractive),
            progress: progress, connectionFailure: nil)
    }

    public func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        try await connect(
            using: SSHConnectionRequest(configuration: configuration),
            progress: progress, connectionFailure: connectionFailure)
    }

    public func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        generation &+= 1
        let token = generation
        let previousChannel = channel
        channel = nil
        let previousConnection = connection
        connection = nil
        await previousChannel?.disconnect()
        await previousConnection?.disconnect()

        let replacement = SSHConnection(logger: logger, maxSessionsPolicy: maxSessionsPolicy)
        do {
            try await replacement.connect(
                using: request.withKeyboardInteractiveFallback(keyboardInteractive),
                progress: progress, connectionFailure: connectionFailure)
            progress?(
                .initializing(
                    request.configuration.hostID,
                    String(localized: "Starting SFTP subsystem")))
            let channel = try await replacement.openSFTPChannel()
            guard generation == token else {
                await channel.disconnect()
                await replacement.disconnect()
                throw CancellationError()
            }
            connection = replacement
            self.channel = channel
        } catch {
            await replacement.disconnect()
            throw error
        }
    }

    public func disconnect() async {
        generation &+= 1
        let channel = channel
        self.channel = nil
        let connection = connection
        self.connection = nil
        await channel?.disconnect()
        await connection?.disconnect()
    }

    public func openSiblingChannel() async throws -> any SFTPChannelProtocol {
        try await connectedChannel().openSiblingChannel()
    }

    public func homeDirectory() async throws -> String {
        try await connectedChannel().homeDirectory()
    }

    public func listDirectory(at path: String) async throws -> [RemoteFile] {
        try await connectedChannel().listDirectory(at: path)
    }

    public func attributes(at path: String) async throws -> RemoteFile? {
        try await connectedChannel().attributes(at: path)
    }

    public func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        try await connectedChannel().readFile(at: path, maximumBytes: maximumBytes)
    }

    public func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage {
        try await connectedChannel().readTextPage(at: path, offset: offset, limit: limit)
    }

    public func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        try await connectedChannel().writeFile(data, at: path, overwrite: overwrite)
    }

    public func setPermissions(at path: String, to permissions: UInt32) async throws {
        try await connectedChannel().setPermissions(at: path, to: permissions)
    }

    public func createDirectory(at path: String) async throws {
        try await connectedChannel().createDirectory(at: path)
    }

    public func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        try await connectedChannel().rename(
            from: source, to: destination, overwrite: overwrite)
    }

    public func removeFile(at path: String) async throws {
        try await connectedChannel().removeFile(at: path)
    }

    public func removeDirectory(at path: String) async throws {
        try await connectedChannel().removeDirectory(at: path)
    }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, resume: resume, progress: progress)
    }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await connectedChannel().uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount,
            overwrite: overwrite, cancellation: cancellation, resume: resume,
            progress: progress, sourceSucceeded: sourceSucceeded)
    }

    public func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await connectedChannel().uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount,
            overwrite: overwrite, cancellation: cancellation,
            progress: progress, sourceSucceeded: sourceSucceeded)
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, resume: resume, progress: progress)
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await connectedChannel().downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    public func openDownloadStream(
        at path: String, maximumBytes: Int64,
        cancellation: TransferCancellationToken
    ) async throws -> any SFTPDownloadStream {
        try await connectedChannel().openDownloadStream(
            at: path, maximumBytes: maximumBytes, cancellation: cancellation)
    }

    public func copyFile(
        from sourcePath: String, to destinationPath: String,
        on destination: any SFTPChannelProtocol, byteCount: Int64,
        overwrite: Bool, cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        let destinationChannel =
            if let destination = destination as? SFTPClient {
                try await destination.connectedChannel()
            } else {
                destination
            }
        try await connectedChannel().copyFile(
            from: sourcePath, to: destinationPath, on: destinationChannel,
            byteCount: byteCount, overwrite: overwrite,
            cancellation: cancellation, progress: progress)
    }

    private func connectedChannel() throws -> any SFTPChannelProtocol {
        guard let channel else { throw SFTPError.notConnected }
        return channel
    }
}

nonisolated final class SFTPSocketRelay: @unchecked Sendable {
    public let writer: Int32
    public let reader: Int32
    private let lock = NSLock()
    private var closed = false
    private var readSucceeded = false
    public var sourceSucceeded: Bool { lock.withLock { readSucceeded } }

    public init() throws {
        var pair: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            throw SFTPError.operation("Unable to create the SFTP copy relay: \(String(cString: strerror(errno)))")
        }
        writer = pair[0]
        reader = pair[1]
        var yes: Int32 = 1
        for descriptor in pair {
            _ = setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
    }

    public func finishWriting() {
        lock.withLock {
            guard !closed else { return }
            readSucceeded = true
            _ = Darwin.shutdown(writer, SHUT_WR)
        }
    }

    public func stop() {
        lock.withLock {
            guard !closed else { return }
            _ = Darwin.shutdown(writer, SHUT_RDWR)
            _ = Darwin.shutdown(reader, SHUT_RDWR)
        }
    }

    public func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            Darwin.close(writer)
            Darwin.close(reader)
        }
    }
}

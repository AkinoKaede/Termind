import AgentKit
import CSSH2
import Darwin
import Foundation
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

    func observeCancellation(_ callback: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let alreadyCancelled = lock.withLock {
            if cancelled { return true }
            observers[id] = callback
            return false
        }
        if alreadyCancelled { callback() }
        return id
    }

    func removeObserver(_ id: UUID) { _ = lock.withLock { observers.removeValue(forKey: id) } }
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
        total: Int64, report: @escaping @Sendable (SFTPProgress) -> Void
    ) {
        self.total = total
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

public nonisolated protocol SFTPClientProtocol: RemoteFileSystem, Sendable {
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
        on destination: any SFTPClientProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws
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
        on destination: any SFTPClientProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        throw SFTPError.operation("This SFTP client does not support streamed remote copying.")
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

public actor SFTPClient: SFTPClientProtocol {
    public init() {}
    private nonisolated let worker = SFTPWorker()

    public func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler? = nil
    ) async throws {
        try await worker.connect(
            using: SSHConnectionRequest(configuration: configuration),
            progress: progress
        )
    }

    public func connect(
        using configuration: SSHConnectionConfiguration,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        try await connect(
            using: SSHConnectionRequest(configuration: configuration),
            progress: progress, connectionFailure: connectionFailure
        )
    }

    public func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {
        try await worker.connect(
            using: request, progress: progress,
            connectionFailure: connectionFailure
        )
    }

    public func disconnect() async { await worker.disconnect() }

    public func homeDirectory() async throws -> String {
        try await worker.homeDirectory()
    }

    public func listDirectory(at path: String) async throws -> [RemoteFile] {
        try await worker.listDirectory(at: path)
    }

    public func attributes(at path: String) async throws -> RemoteFile? {
        try await worker.attributes(at: path)
    }

    public func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        try await worker.readFile(at: path, maximumBytes: maximumBytes)
    }

    public func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage {
        try await worker.readTextPage(at: path, offset: offset, limit: limit)
    }

    public func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        try await worker.writeFile(data, at: path, overwrite: overwrite)
    }

    public func setPermissions(at path: String, to permissions: UInt32) async throws {
        try await worker.setPermissions(at: path, to: permissions)
    }

    public func createDirectory(at path: String) async throws {
        try await worker.createDirectory(at: path)
    }

    public func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        try await worker.rename(from: source, to: destination, overwrite: overwrite)
    }

    public func removeFile(at path: String) async throws { try await worker.removeFile(at: path) }
    public func removeDirectory(at path: String) async throws { try await worker.removeDirectory(at: path) }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await worker.uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, progress: progress
        )
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await worker.downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, progress: progress
        )
    }

    public func copyFile(
        from sourcePath: String,
        to destinationPath: String,
        on destination: any SFTPClientProtocol,
        byteCount: Int64,
        overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        guard let destination = destination as? SFTPClient else {
            throw SFTPError.operation("The destination cannot receive a streamed SFTP copy.")
        }
        let relay = try SFTPSocketRelay()
        let observer = cancellation.observeCancellation { relay.stop() }
        defer {
            cancellation.removeObserver(observer)
            relay.close()
        }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    do {
                        try await self.worker.downloadFile(
                            from: sourcePath, toSocket: relay.writer,
                            cancellation: cancellation
                        )
                        relay.finishWriting()
                    } catch {
                        cancellation.cancel()
                        throw error
                    }
                }
                group.addTask {
                    try await destination.worker.uploadFile(
                        fromSocket: relay.reader, to: destinationPath,
                        byteCount: byteCount, overwrite: overwrite,
                        cancellation: cancellation, progress: progress,
                        sourceSucceeded: { relay.sourceSucceeded }
                    )
                }
                do {
                    while try await group.next() != nil {}
                } catch {
                    cancellation.cancel()
                    relay.stop()
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
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

private nonisolated final class SFTPWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.sftp")
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var sftp: OpaquePointer?
    private var keepaliveTimer: (any DispatchSourceTimer)?
    private var connectionFailure: (@Sendable (String) -> Void)?
    private var didReportConnectionFailure = false

    deinit { cleanup() }

    public func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)? = nil
    ) async throws {
        await queue.perform { self.cleanup() }
        let opened = try await SSHSessionWorker.openAuthenticatedSession(
            using: request, timeout: 20, progress: progress
        )
        do {
            try await queue.perform {
                self.routeTransport = opened.transport
                self.session = opened.session
                let session = opened.session
                progress?(.initializing(request.configuration.hostID, String(localized: "Starting SFTP subsystem")))
                guard let sftp = libssh2_sftp_init(session) else {
                    throw SSHSessionWorker.sessionError(session, prefix: "Unable to start SFTP")
                }
                self.sftp = sftp
                self.connectionFailure = connectionFailure
                self.didReportConnectionFailure = false
                self.startKeepalive(for: session)
            }
            try Task.checkCancellation()
        } catch {
            await queue.perform { self.cleanup() }
            throw error
        }
    }

    public func disconnect() async { await queue.perform { self.cleanup() } }

    public func homeDirectory() async throws -> String {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            let source = "."
            var target = [CChar](repeating: 0, count: 4 * 1024)
            let count = source.withCString { sourceBuffer in
                libssh2_sftp_symlink_ex(
                    sftp, sourceBuffer, UInt32(source.utf8.count),
                    &target, UInt32(target.count), Int32(LIBSSH2_SFTP_REALPATH)
                )
            }
            guard count > 0 else { throw self.error("Unable to resolve the remote home directory") }
            let bytes = target.prefix(Int(count)).map { UInt8(bitPattern: $0) }
            return RemotePath.normalized(String(decoding: bytes, as: UTF8.self))
        }
    }

    public func listDirectory(at path: String) async throws -> [RemoteFile] {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            guard
                let handle = path.withCString({
                    libssh2_sftp_open_ex(
                        sftp, $0, UInt32(path.utf8.count), 0, 0,
                        Int32(LIBSSH2_SFTP_OPENDIR)
                    )
                })
            else {
                throw self.error("Unable to open \(path)")
            }
            defer { _ = libssh2_sftp_close_handle(handle) }
            var result: [RemoteFile] = []
            var name = [CChar](repeating: 0, count: 4 * 1024)
            while true {
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let count = libssh2_sftp_readdir_ex(
                    handle, &name, name.count, nil, 0, &attributes
                )
                if count > 0 {
                    let bytes = name.prefix(Int(count)).map { UInt8(bitPattern: $0) }
                    let filename = String(decoding: bytes, as: UTF8.self)
                    guard filename != ".", filename != ".." else { continue }
                    result.append(
                        Self.remoteFile(path: Self.join(path, filename), name: filename, attributes: attributes))
                } else if count == 0 {
                    break
                } else {
                    throw self.error("Unable to read \(path)")
                }
            }
            return result.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    public func attributes(at path: String) async throws -> RemoteFile? {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = path.withCString {
                libssh2_sftp_stat_ex(sftp, $0, UInt32(path.utf8.count), Int32(LIBSSH2_SFTP_LSTAT), &attributes)
            }
            if result == 0 {
                return Self.remoteFile(
                    path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                    attributes: attributes
                )
            }
            if libssh2_sftp_last_error(sftp) == LIBSSH2_FX_NO_SUCH_FILE { return nil }
            throw self.error("Unable to inspect \(path)")
        }
    }

    public func readTextPage(at path: String, offset: Int, limit: Int) async throws -> AgentTextPage {
        try Task.checkCancellation()
        let cancellation = TransferCancellationToken()
        return try await withTaskCancellationHandler {
            try await queue.perform {
                var reader = try AgentTextPageReader(offset: offset, limit: limit)
                return try self.withRemoteReadHandle(at: path) { handle in
                    var buffer = [CChar](repeating: 0, count: 16 * 1_024)
                    while !reader.isComplete {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        let count = libssh2_sftp_read(handle, &buffer, buffer.count)
                        if count > 0 {
                            try reader.append(Data(bytes: buffer, count: count))
                        } else if count == 0 {
                            break
                        } else {
                            throw self.error("Unable to read \(path)")
                        }
                    }
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    return try reader.finish()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        try await queue.perform {
            guard maximumBytes > 0 else { return Data() }
            return try self.withRemoteReadHandle(at: path) { handle in
                var data = Data()
                var buffer = [CChar](repeating: 0, count: min(64 * 1024, maximumBytes + 1))
                while data.count <= maximumBytes {
                    let wanted = min(buffer.count, maximumBytes + 1 - data.count)
                    let count = libssh2_sftp_read(handle, &buffer, wanted)
                    if count > 0 {
                        data.append(Data(bytes: buffer, count: count))
                    } else if count == 0 {
                        break
                    } else {
                        throw self.error("Unable to read \(path)")
                    }
                }
                guard data.count <= maximumBytes else {
                    throw SFTPError.operation("\(path) exceeds the inline read limit of \(maximumBytes) bytes.")
                }
                return data
            }
        }
    }

    public func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            if !overwrite {
                var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                let exists = path.withCString {
                    libssh2_sftp_stat_ex(
                        sftp, $0, UInt32(path.utf8.count),
                        Int32(LIBSSH2_SFTP_LSTAT), &attributes
                    ) == 0
                }
                if exists { throw SFTPError.operation("\(path) already exists.") }
            }
            try self.withAtomicRemoteWrite(
                sftp: sftp, destination: path, overwrite: overwrite,
                temporaryTag: ".termind-agent-part-"
            ) { handle in
                try data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                        return
                    }
                    var offset = 0
                    while offset < bytes.count {
                        let written = libssh2_sftp_write(
                            handle, base.advanced(by: offset), bytes.count - offset
                        )
                        guard written > 0 else { throw self.error("Unable to write \(path)") }
                        offset += written
                    }
                }
            }
        }
    }

    public func setPermissions(at path: String, to permissions: UInt32) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attributes.permissions = UInt(permissions & 0o7777)
            let result = path.withCString {
                libssh2_sftp_stat_ex(
                    sftp, $0, UInt32(path.utf8.count),
                    Int32(LIBSSH2_SFTP_SETSTAT), &attributes
                )
            }
            guard result == 0 else {
                throw self.error("Unable to change permissions for \(path)")
            }
        }
    }

    public func createDirectory(at path: String) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            let result = path.withCString {
                libssh2_sftp_mkdir_ex(sftp, $0, UInt32(path.utf8.count), 0o755)
            }
            guard result == 0 else { throw self.error("Unable to create \(path)") }
        }
    }

    public func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            let flags = overwrite ? Int(LIBSSH2_SFTP_RENAME_OVERWRITE) : 0
            let result = source.withCString { sourceBuffer in
                destination.withCString { destinationBuffer in
                    libssh2_sftp_rename_ex(
                        sftp, sourceBuffer, UInt32(source.utf8.count),
                        destinationBuffer, UInt32(destination.utf8.count), flags
                    )
                }
            }
            guard result == 0 else { throw self.error("Unable to rename \(source)") }
        }
    }

    public func removeFile(at path: String) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            guard
                path.withCString({
                    libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.utf8.count))
                }) == 0
            else {
                throw self.error("Unable to delete \(path)")
            }
        }
    }

    public func removeDirectory(at path: String) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            guard
                path.withCString({
                    libssh2_sftp_rmdir_ex(sftp, $0, UInt32(path.utf8.count))
                }) == 0
            else {
                throw self.error("Unable to delete \(path)")
            }
        }
    }

    public func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            let file: FileHandle
            do { file = try FileHandle(forReadingFrom: localURL) } catch {
                throw SFTPError.localFile(error.localizedDescription)
            }
            defer { try? file.close() }
            try self.withAtomicRemoteWrite(
                sftp: sftp, destination: remotePath, overwrite: overwrite
            ) { handle in
                let total =
                    (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init) ?? 0
                var meter = SFTPProgressMeter(total: total, report: progress)
                while true {
                    if cancellation.isCancelled { throw SFTPError.cancelled }
                    let data = try file.read(upToCount: 64 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try data.withUnsafeBytes { bytes in
                        guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                        else { return }
                        var offset = 0
                        while offset < bytes.count {
                            if cancellation.isCancelled { throw SFTPError.cancelled }
                            let written = libssh2_sftp_write(
                                handle, base.advanced(by: offset), bytes.count - offset
                            )
                            guard written > 0 else {
                                throw self.error("Unable to upload \(remotePath)")
                            }
                            offset += written
                            meter.add(written)
                        }
                    }
                }
                meter.finish()
            }
        }
    }

    public func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await queue.perform {
            try self.withRemoteReadHandle(at: remotePath) { handle in
                let fm = FileManager.default
                let temporary = localURL.deletingLastPathComponent().appendingPathComponent(
                    ".termind-part-\(UUID().uuidString)")
                guard fm.createFile(atPath: temporary.path, contents: nil) else {
                    throw SFTPError.localFile("Unable to create \(temporary.path)")
                }
                var succeeded = false
                defer { if !succeeded { try? fm.removeItem(at: temporary) } }
                let file = try FileHandle(forWritingTo: temporary)
                defer { try? file.close() }
                var attrs = LIBSSH2_SFTP_ATTRIBUTES()
                _ = libssh2_sftp_fstat_ex(handle, &attrs, 0)
                let total = Int64(attrs.filesize)
                var meter = SFTPProgressMeter(total: total, report: progress)
                var buffer = [CChar](repeating: 0, count: 64 * 1024)
                while true {
                    if cancellation.isCancelled { throw SFTPError.cancelled }
                    let count = libssh2_sftp_read(handle, &buffer, buffer.count)
                    if count > 0 {
                        try file.write(contentsOf: Data(bytes: buffer, count: count))
                        meter.add(count)
                    } else if count == 0 {
                        break
                    } else {
                        throw self.error("Unable to download \(remotePath)")
                    }
                }
                try file.synchronize()
                meter.finish()
                if fm.fileExists(atPath: localURL.path) {
                    guard overwrite else { throw SFTPError.localFile("\(localURL.lastPathComponent) already exists.") }
                    _ = try fm.replaceItemAt(localURL, withItemAt: temporary)
                } else {
                    try fm.moveItem(at: temporary, to: localURL)
                }
                succeeded = true
            }
        }
    }

    public func downloadFile(
        from remotePath: String, toSocket socket: Int32,
        cancellation: TransferCancellationToken
    ) async throws {
        try await queue.perform {
            try self.withRemoteReadHandle(at: remotePath) { handle in
                var buffer = [CChar](repeating: 0, count: 64 * 1024)
                while true {
                    if cancellation.isCancelled { throw SFTPError.cancelled }
                    let count = libssh2_sftp_read(handle, &buffer, buffer.count)
                    if count > 0 {
                        var offset = 0
                        while offset < count {
                            if cancellation.isCancelled { throw SFTPError.cancelled }
                            let sent = buffer.withUnsafeBytes { bytes in
                                Darwin.send(
                                    socket, bytes.baseAddress!.advanced(by: offset),
                                    count - offset, 0
                                )
                            }
                            if sent > 0 {
                                offset += sent
                            } else if sent < 0, errno == EINTR {
                                continue
                            } else {
                                throw SFTPError.operation("The SFTP copy relay was interrupted.")
                            }
                        }
                    } else if count == 0 {
                        break
                    } else {
                        throw self.error("Unable to read \(remotePath)")
                    }
                }
            }
        }
    }

    public func uploadFile(
        fromSocket socket: Int32, to remotePath: String,
        byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await queue.perform {
            let sftp = try self.requireSFTP()
            try self.withAtomicRemoteWrite(
                sftp: sftp, destination: remotePath, overwrite: overwrite
            ) { handle in
                var meter = SFTPProgressMeter(total: byteCount, report: progress)
                var buffer = [CChar](repeating: 0, count: 64 * 1024)
                while true {
                    if cancellation.isCancelled { throw SFTPError.cancelled }
                    let count = Darwin.recv(socket, &buffer, buffer.count, 0)
                    if count > 0 {
                        guard Int64(count) <= byteCount - meter.completed else {
                            throw SFTPError.operation(String(localized: "The SFTP copy source grew during transfer."))
                        }
                        try buffer.withUnsafeBytes { bytes in
                            guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self)
                            else { return }
                            var offset = 0
                            while offset < count {
                                if cancellation.isCancelled { throw SFTPError.cancelled }
                                let written = libssh2_sftp_write(
                                    handle, base.advanced(by: offset), count - offset
                                )
                                guard written > 0 else {
                                    throw self.error("Unable to copy to \(remotePath)")
                                }
                                offset += written
                                meter.add(written)
                            }
                        }
                    } else if count == 0 {
                        break
                    } else if errno != EINTR {
                        throw SFTPError.operation("The SFTP copy relay was interrupted.")
                    }
                }
                guard !cancellation.isCancelled, sourceSucceeded() else { throw SFTPError.cancelled }
                guard meter.completed == byteCount else {
                    throw SFTPError.operation(
                        "The source changed while it was being copied "
                            + "(expected \(byteCount) bytes, received \(meter.completed))."
                    )
                }
                meter.finish()
            }
        }
    }

    private func withRemoteReadHandle<T>(
        at path: String, read: (OpaquePointer) throws -> T
    ) throws -> T {
        let sftp = try requireSFTP()
        guard
            let handle = path.withCString({
                libssh2_sftp_open_ex(
                    sftp, $0, UInt32(path.utf8.count), UInt(LIBSSH2_FXF_READ), 0,
                    Int32(LIBSSH2_SFTP_OPENFILE)
                )
            })
        else {
            throw error("Unable to open \(path)")
        }
        defer { _ = libssh2_sftp_close_handle(handle) }
        return try read(handle)
    }

    private func withAtomicRemoteWrite(
        sftp: OpaquePointer,
        destination: String,
        overwrite: Bool,
        temporaryTag: String = ".termind-part-",
        write: (OpaquePointer) throws -> Void
    ) throws {
        let temporary = destination + temporaryTag + UUID().uuidString
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        guard
            let handle = temporary.withCString({
                libssh2_sftp_open_ex(
                    sftp, $0, UInt32(temporary.utf8.count), flags, 0o600,
                    Int32(LIBSSH2_SFTP_OPENFILE)
                )
            })
        else {
            throw error("Unable to create \(destination)")
        }
        var succeeded = false
        defer {
            _ = libssh2_sftp_close_handle(handle)
            if !succeeded {
                _ = temporary.withCString {
                    libssh2_sftp_unlink_ex(sftp, $0, UInt32(temporary.utf8.count))
                }
            }
        }
        try write(handle)
        try renameOnQueue(
            sftp: sftp, from: temporary, to: destination, overwrite: overwrite
        )
        succeeded = true
    }

    private func renameOnQueue(sftp: OpaquePointer, from source: String, to destination: String, overwrite: Bool) throws
    {
        let flags = overwrite ? Int(LIBSSH2_SFTP_RENAME_OVERWRITE) : 0
        let result = source.withCString { sourceBuffer in
            destination.withCString { destinationBuffer in
                libssh2_sftp_rename_ex(
                    sftp, sourceBuffer, UInt32(source.utf8.count),
                    destinationBuffer, UInt32(destination.utf8.count), flags
                )
            }
        }
        guard result == 0 else { throw error("Unable to finish \(destination)") }
    }

    private func requireSFTP() throws -> OpaquePointer {
        guard let sftp else { throw SFTPError.notConnected }
        return sftp
    }

    private func error(_ prefix: String) -> SFTPError {
        guard let sftp else { return .operation(prefix) }
        let sftpCode = libssh2_sftp_last_error(sftp)
        let sessionCode = session.map(libssh2_session_last_errno) ?? 0
        let message = "\(prefix): SFTP error \(sftpCode)"
        let lostSFTPCodes = [
            UInt(LIBSSH2_FX_NO_CONNECTION), UInt(LIBSSH2_FX_CONNECTION_LOST),
        ]
        let lostSessionCodes = [
            LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_CHANNEL_CLOSED,
        ]
        if lostSFTPCodes.contains(sftpCode) || lostSessionCodes.contains(sessionCode) {
            reportConnectionFailure(message)
            return .connectionLost(message)
        }
        return .operation(message)
    }

    private func cleanup() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let sftp {
            _ = libssh2_sftp_shutdown(sftp)
            self.sftp = nil
        }
        if let session {
            _ = libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "Termind closed SFTP", "")
            _ = libssh2_session_free(session)
            self.session = nil
        }
        routeTransport?.close()
        routeTransport = nil
        connectionFailure = nil
        didReportConnectionFailure = false
    }

    private func startKeepalive(for session: OpaquePointer) {
        libssh2_keepalive_config(session, 1, 15)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.session == session else { return }
            var secondsToNext: Int32 = 0
            let result = libssh2_keepalive_send(session, &secondsToNext)
            if result < 0, result != LIBSSH2_ERROR_EAGAIN {
                let error = SSHSessionWorker.sessionError(
                    session, prefix: "SFTP keepalive failed"
                )
                self.reportConnectionFailure(error.localizedDescription)
            }
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func reportConnectionFailure(_ message: String) {
        guard !didReportConnectionFailure else { return }
        didReportConnectionFailure = true
        connectionFailure?(message)
    }

    private static func join(_ base: String, _ component: String) -> String {
        base == "/" ? "/\(component)" : "\(base)/\(component)"
    }

    private static func remoteFile(
        path: String, name: String, attributes: LIBSSH2_SFTP_ATTRIBUTES
    ) -> RemoteFile {
        let mode = UInt32(attributes.permissions)
        let kind: RemoteFile.Kind
        if mode & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFDIR) {
            kind = .directory
        } else if mode & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFREG) {
            kind = .file
        } else if mode & UInt32(LIBSSH2_SFTP_S_IFMT) == UInt32(LIBSSH2_SFTP_S_IFLNK) {
            kind = .symbolicLink
        } else if mode == 0 {
            kind = .unknown
        } else {
            kind = .special
        }
        return RemoteFile(
            path: path, name: name, kind: kind, size: Int64(attributes.filesize),
            modifiedAt: attributes.mtime == 0 ? nil : Date(timeIntervalSince1970: TimeInterval(attributes.mtime)),
            permissions: mode, ownerUID: UInt32(attributes.uid), ownerGID: UInt32(attributes.gid)
        )
    }
}

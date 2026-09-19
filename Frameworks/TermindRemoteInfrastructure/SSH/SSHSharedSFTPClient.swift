import AgentKit
import CSSH2
import CryptoKit
import Darwin
import Foundation
import TermindApplication
import TermindDomain

nonisolated enum SSHSharedSFTPAttempt<Value: Sendable>: Sendable {
    case value(Value)
    case again
}

nonisolated final class SSHSharedSFTPValue: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

nonisolated enum SSHSharedSFTPAnyAttempt: @unchecked Sendable {
    case value(SSHSharedSFTPValue)
    case again
}

/// Type-erased access to a non-blocking libssh2 owner. The PTY and Agent
/// workers keep their own pumps and lifetimes; this driver lets one complete
/// SFTP implementation take bounded turns on either owner.
nonisolated final class SSHSharedSFTPDriver: @unchecked Sendable {
    typealias RawOperation = @Sendable (OpaquePointer, OpaquePointer) throws -> SSHSharedSFTPAnyAttempt

    let identity: UUID
    private let openAction: @Sendable () async throws -> UUID
    private let closeAction: @Sendable (UUID) async -> Void
    private let performAction: @Sendable (UUID, @escaping RawOperation) async throws -> SSHSharedSFTPValue

    init(
        identity: UUID,
        open: @escaping @Sendable () async throws -> UUID,
        close: @escaping @Sendable (UUID) async -> Void,
        perform: @escaping @Sendable (UUID, @escaping RawOperation) async throws -> SSHSharedSFTPValue
    ) {
        self.identity = identity
        openAction = open
        closeAction = close
        performAction = perform
    }

    func open() async throws -> UUID { try await openAction() }
    func close(_ id: UUID) async { await closeAction(id) }

    func perform<Value: Sendable>(
        _ id: UUID,
        _ operation: @escaping @Sendable (OpaquePointer, OpaquePointer) throws -> SSHSharedSFTPAttempt<Value>
    ) async throws -> Value {
        let boxed = try await performAction(id) { session, sftp in
            switch try operation(session, sftp) {
            case .value(let value): .value(SSHSharedSFTPValue(value))
            case .again: .again
            }
        }
        guard let value = boxed.value as? Value else {
            preconditionFailure("Shared SFTP driver returned an unexpected value type")
        }
        return value
    }
}

private nonisolated final class SSHSharedSFTPHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

private nonisolated final class SSHSharedSFTPWriteContext: @unchecked Sendable {
    let handle: OpaquePointer
    let temporary: String
    let destination: String
    let overwrite: Bool
    var handleOpen = true

    init(handle: OpaquePointer, temporary: String, destination: String, overwrite: Bool) {
        self.handle = handle
        self.temporary = temporary
        self.destination = destination
        self.overwrite = overwrite
    }
}

private nonisolated struct SSHSharedSFTPProgressMeter {
    let total: Int64
    let report: @Sendable (SFTPProgress) -> Void
    private(set) var completed: Int64
    private var sampledBytes: Int64 = 0
    private var sampledAt = ContinuousClock.now

    init(total: Int64, offset: Int64 = 0, report: @escaping @Sendable (SFTPProgress) -> Void) {
        self.total = total
        completed = offset
        self.report = report
    }

    mutating func add(_ bytes: Int) {
        completed += Int64(bytes)
        sampledBytes += Int64(bytes)
        let elapsed = sampledAt.duration(to: .now)
        guard elapsed >= .milliseconds(250) else { return }
        let parts = elapsed.components
        let seconds = max(0.001, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        report(
            SFTPProgress(
                completedBytes: completed, totalBytes: total,
                bytesPerSecond: Int64(Double(sampledBytes) / seconds)))
        sampledBytes = 0
        sampledAt = .now
    }

    func finish() {
        report(SFTPProgress(completedBytes: completed, totalBytes: total, bytesPerSecond: 0))
    }
}

/// An SFTP subsystem Channel on a shared non-blocking SSH transport.
actor SSHSharedSFTPClient: SFTPClientProtocol {
    private nonisolated let driver: SSHSharedSFTPDriver
    private let id: UUID
    private var disconnected = false

    static func open(using driver: SSHSharedSFTPDriver) async throws -> any SFTPClientProtocol {
        let id = try await driver.open()
        do {
            try Task.checkCancellation()
            return SSHSharedSFTPClient(driver: driver, id: id)
        } catch {
            await driver.close(id)
            throw error
        }
    }

    private init(driver: SSHSharedSFTPDriver, id: UUID) {
        self.driver = driver
        self.id = id
    }

    deinit {
        let driver = driver
        let id = id
        Task { await driver.close(id) }
    }

    func openSiblingChannel() async throws -> any SFTPClientProtocol {
        try await Self.open(using: driver)
    }

    func connect(using configuration: SSHConnectionConfiguration, progress: SSHRouteProgressHandler?) async throws {}

    func connect(
        using request: SSHConnectionRequest, progress: SSHRouteProgressHandler?,
        connectionFailure: (@Sendable (String) -> Void)?
    ) async throws {}

    func disconnect() async {
        guard !disconnected else { return }
        disconnected = true
        await driver.close(id)
    }

    func homeDirectory() async throws -> String {
        try await driver.perform(id) { session, sftp in
            let source = "."
            var target = [CChar](repeating: 0, count: 4 * 1024)
            let count = source.withCString {
                libssh2_sftp_symlink_ex(
                    sftp, $0, UInt32(source.utf8.count), &target, UInt32(target.count),
                    Int32(LIBSSH2_SFTP_REALPATH))
            }
            if count == LIBSSH2_ERROR_EAGAIN { return .again }
            guard count > 0 else { throw Self.error(session, sftp, "Unable to resolve the remote home directory") }
            return .value(
                RemotePath.normalized(
                    String(decoding: target.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)))
        }
    }

    func listDirectory(at path: String) async throws -> [RemoteFile] {
        let handle = try await openHandle(path: path, flags: 0, mode: 0, type: Int32(LIBSSH2_SFTP_OPENDIR))
        var files: [RemoteFile] = []
        do {
            while true {
                let next: RemoteFile? = try await driver.perform(id) { session, sftp in
                    var name = [CChar](repeating: 0, count: 4 * 1024)
                    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                    let count = libssh2_sftp_readdir_ex(
                        handle.pointer, &name, name.count, nil, 0, &attributes)
                    if count == LIBSSH2_ERROR_EAGAIN { return .again }
                    guard count >= 0 else { throw Self.error(session, sftp, "Unable to read \(path)") }
                    guard count > 0 else { return .value(nil) }
                    let filename = String(
                        decoding: name.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    return .value(
                        Self.remoteFile(
                            path: RemotePath.join(path, filename), name: filename,
                            attributes: attributes))
                }
                guard let next else { break }
                if next.name != "." && next.name != ".." { files.append(next) }
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        return files.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func attributes(at path: String) async throws -> RemoteFile? {
        try await driver.perform(id) { session, sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = path.withCString {
                libssh2_sftp_stat_ex(
                    sftp, $0, UInt32(path.utf8.count), Int32(LIBSSH2_SFTP_LSTAT), &attributes)
            }
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            if result == 0 { return .value(Self.remoteFile(path: path, attributes: attributes)) }
            if libssh2_sftp_last_error(sftp) == LIBSSH2_FX_NO_SUCH_FILE { return .value(nil) }
            throw Self.error(session, sftp, "Unable to inspect \(path)")
        }
    }

    func readFile(at path: String, maximumBytes: Int) async throws -> Data {
        guard maximumBytes >= 0 else { throw SFTPError.operation("The inline read limit is invalid.") }
        let handle = try await openHandle(
            path: path, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
            type: Int32(LIBSSH2_SFTP_OPENFILE))
        var data = Data()
        do {
            while data.count <= maximumBytes {
                let wanted = min(64 * 1024, maximumBytes + 1 - data.count)
                if wanted == 0 { break }
                let chunk: Data? = try await read(handle, maximumBytes: wanted)
                guard let chunk else { break }
                data.append(chunk)
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
        guard data.count <= maximumBytes else {
            throw SFTPError.operation("\(path) exceeds the inline read limit of \(maximumBytes) bytes.")
        }
        return data
    }

    func writeFile(_ data: Data, at path: String, overwrite: Bool) async throws {
        let temporary = path + ".termind-write-" + UUID().uuidString.lowercased()
        let context = try await beginWrite(
            temporary: temporary, destination: path, overwrite: overwrite,
            continuing: false, snapshot: nil)
        do {
            try await write(data, to: context.handle, cancellation: nil, acknowledge: nil)
            try await closeHandle(SSHSharedSFTPHandle(context.handle))
            context.handleOpen = false
            if let existing = try await attributes(at: path), !overwrite || existing.isDirectory {
                throw SFTPStreamUploadOperation.Failure.targetConflict
            }
            try await rename(from: temporary, to: path, overwrite: overwrite)
        } catch {
            if context.handleOpen { try? await closeHandle(SSHSharedSFTPHandle(context.handle)) }
            try? await removeFile(at: temporary)
            throw error
        }
    }

    func setPermissions(at path: String, to permissions: UInt32) async throws {
        try await performStatus(prefix: "Unable to change permissions for \(path)") { sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attributes.permissions = UInt(permissions & 0o7777)
            return path.withCString {
                libssh2_sftp_stat_ex(
                    sftp, $0, UInt32(path.utf8.count), Int32(LIBSSH2_SFTP_SETSTAT), &attributes)
            }
        }
    }

    func createDirectory(at path: String) async throws {
        try await performStatus(prefix: "Unable to create \(path)") { sftp in
            path.withCString { libssh2_sftp_mkdir_ex(sftp, $0, UInt32(path.utf8.count), 0o755) }
        }
    }

    func rename(from source: String, to destination: String, overwrite: Bool) async throws {
        let flags = overwrite ? Int(LIBSSH2_SFTP_RENAME_OVERWRITE) : 0
        let _: Void = try await driver.perform(id) { session, sftp in
            let result = source.withCString { sourceBuffer in
                destination.withCString { destinationBuffer in
                    SFTPRenameOperation.perform(
                        overwrite: overwrite,
                        posixRename: {
                            libssh2_sftp_posix_rename_ex(
                                sftp, sourceBuffer, source.utf8.count,
                                destinationBuffer, destination.utf8.count)
                        },
                        standardRename: {
                            libssh2_sftp_rename_ex(
                                sftp, sourceBuffer, UInt32(source.utf8.count), destinationBuffer,
                                UInt32(destination.utf8.count), flags)
                        },
                        lastStatus: { libssh2_sftp_last_error(sftp) })
                }
            }
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            guard result == 0 else { throw Self.error(session, sftp, "Unable to rename \(source)") }
            return .value(())
        }
    }

    func removeFile(at path: String) async throws {
        try await performStatus(prefix: "Unable to delete \(path)") { sftp in
            path.withCString { libssh2_sftp_unlink_ex(sftp, $0, UInt32(path.utf8.count)) }
        }
    }

    func removeDirectory(at path: String) async throws {
        try await performStatus(prefix: "Unable to delete \(path)") { sftp in
            path.withCString { libssh2_sftp_rmdir_ex(sftp, $0, UInt32(path.utf8.count)) }
        }
    }

    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        guard resume.snapshot.editPolicy == nil else { throw SFTPEditFailure.unsupported }
        if resume.snapshot.committed { return }
        let values = try localURL.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw SFTPResumeFailure.sourceChanged
        }
        let identity = SFTPSourceIdentity(byteCount: Int64(size), modifiedAt: values.contentModificationDate)
        try resume.validateSource(identity)
        let snapshot = resume.snapshot
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        try Self.verifyLocalPrefix(file, snapshot: snapshot, cancellation: cancellation)
        let context = try await beginWrite(
            temporary: resume.temporaryPath(for: remotePath), destination: remotePath,
            overwrite: overwrite, continuing: snapshot.hasTemporaryFile, snapshot: snapshot)
        if !snapshot.hasTemporaryFile { resume.createdTemporaryFile() }
        do {
            var meter = SSHSharedSFTPProgressMeter(
                total: identity.byteCount, offset: snapshot.offset, report: progress)
            while true {
                guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                let data = try file.read(upToCount: 32_700) ?? Data()
                if data.isEmpty { break }
                guard Int64(data.count) <= identity.byteCount - meter.completed else {
                    throw SFTPResumeFailure.sourceChanged
                }
                try await write(data, to: context.handle, cancellation: cancellation) { chunk in
                    resume.acknowledge(chunk)
                    meter.add(chunk.count)
                }
            }
            guard meter.completed == identity.byteCount else { throw SFTPResumeFailure.sourceChanged }
            guard try Self.localIdentity(localURL) == identity else { throw SFTPResumeFailure.sourceChanged }
            try await finishWrite(context, resume: resume)
            meter.finish()
        } catch {
            if context.handleOpen { try? await closeHandle(SSHSharedSFTPHandle(context.handle)) }
            throw error
        }
    }

    func uploadFile(
        from localURL: URL, to remotePath: String, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await uploadFile(
            from: localURL, to: remotePath, overwrite: overwrite,
            cancellation: cancellation, resume: SFTPResumeState(), progress: progress)
    }

    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        if resume.snapshot.committed { return }
        let handle = try await openHandle(
            path: remotePath, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
            type: Int32(LIBSSH2_SFTP_OPENFILE))
        var handleOpen = true
        do {
            let identity = try await remoteIdentity(handle)
            try resume.validateSource(identity)
            let snapshot = resume.snapshot
            let temporary = URL(fileURLWithPath: resume.temporaryPath(for: localURL.path))
            let fm = FileManager.default
            if !snapshot.hasTemporaryFile {
                guard fm.createFile(atPath: temporary.path, contents: nil) else {
                    throw SFTPError.localFile("Unable to create \(temporary.path)")
                }
                resume.createdTemporaryFile()
            }
            let file = try FileHandle(forUpdating: temporary)
            defer { try? file.close() }
            guard try file.seekToEnd() == UInt64(snapshot.offset) else {
                throw SFTPResumeFailure.partialChanged
            }
            try file.seek(toOffset: 0)
            try Self.verifyLocalPrefix(file, snapshot: snapshot, cancellation: cancellation)
            try await verifyRemotePrefix(handle, snapshot: snapshot, cancellation: cancellation)
            try file.seek(toOffset: UInt64(snapshot.offset))
            var meter = SSHSharedSFTPProgressMeter(
                total: identity.byteCount, offset: snapshot.offset, report: progress)
            while let data = try await read(handle, maximumBytes: 32_700) {
                guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                guard Int64(data.count) <= identity.byteCount - meter.completed else {
                    throw SFTPResumeFailure.sourceChanged
                }
                try file.write(contentsOf: data)
                resume.acknowledge(data)
                meter.add(data.count)
            }
            guard meter.completed == identity.byteCount,
                try await remoteIdentity(handle) == identity
            else { throw SFTPResumeFailure.sourceChanged }
            try await closeHandle(handle)
            handleOpen = false
            try file.synchronize()
            meter.finish()
            resume.willCommit()
            if fm.fileExists(atPath: localURL.path) {
                guard overwrite else {
                    throw SFTPError.localFile("\(localURL.lastPathComponent) already exists.")
                }
                _ = try fm.replaceItemAt(localURL, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: localURL)
            }
            resume.didCommit()
        } catch {
            if handleOpen { try? await closeHandle(handle) }
            throw error
        }
    }

    func downloadFile(
        from remotePath: String, to localURL: URL, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        try await downloadFile(
            from: remotePath, to: localURL, overwrite: overwrite,
            cancellation: cancellation, resume: SFTPResumeState(), progress: progress)
    }

    func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, resume: SFTPResumeState,
        progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        guard resume.snapshot.editPolicy == nil else { throw SFTPEditFailure.unsupported }
        if resume.snapshot.committed { return }
        let snapshot = resume.snapshot
        let context = try await beginWrite(
            temporary: resume.temporaryPath(for: remotePath), destination: remotePath,
            overwrite: overwrite, continuing: snapshot.hasTemporaryFile, snapshot: snapshot)
        if !snapshot.hasTemporaryFile { resume.createdTemporaryFile() }
        do {
            var meter = SSHSharedSFTPProgressMeter(total: byteCount, offset: snapshot.offset, report: progress)
            while true {
                guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                var buffer = [UInt8](repeating: 0, count: 32_700)
                let count = Darwin.recv(socket, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR { continue }
                if count < 0 {
                    throw SFTPError.operation("The SFTP upload stream was interrupted.")
                }
                if count == 0 { break }
                let data = Data(buffer.prefix(count))
                guard Int64(data.count) <= byteCount - meter.completed else {
                    throw SFTPError.operation("The SFTP upload source exceeded the declared length.")
                }
                try await write(data, to: context.handle, cancellation: cancellation) { chunk in
                    resume.acknowledge(chunk)
                    meter.add(chunk.count)
                }
            }
            guard !cancellation.isCancelled, sourceSucceeded() else { throw SFTPError.cancelled }
            guard meter.completed == byteCount else {
                throw SFTPError.operation(
                    "The SFTP upload source ended before the declared length.")
            }
            try await finishWrite(context, resume: resume)
            meter.finish()
        } catch {
            if context.handleOpen { try? await closeHandle(SSHSharedSFTPHandle(context.handle)) }
            throw error
        }
    }

    func uploadStream(
        fromSocket socket: Int32, to remotePath: String, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken, progress: @escaping @Sendable (SFTPProgress) -> Void,
        sourceSucceeded: @escaping @Sendable () -> Bool
    ) async throws {
        try await uploadStream(
            fromSocket: socket, to: remotePath, byteCount: byteCount, overwrite: overwrite,
            cancellation: cancellation, resume: SFTPResumeState(), progress: progress,
            sourceSucceeded: sourceSucceeded)
    }

    func openDownloadStream(
        at path: String, maximumBytes: Int64, cancellation: TransferCancellationToken
    ) async throws -> any SFTPDownloadStream {
        let handle = try await openHandle(
            path: path, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
            type: Int32(LIBSSH2_SFTP_OPENFILE))
        do {
            let identity = try await remoteIdentity(handle)
            guard identity.byteCount <= maximumBytes else { throw SFTPDownloadFailure.tooLarge }
            return SSHSharedSFTPDownloadStream(
                client: self, handle: handle, identity: identity, cancellation: cancellation)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
    }

    func copyFile(
        from sourcePath: String, to destinationPath: String,
        on destination: any SFTPClientProtocol, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        if let destination = destination as? SSHSharedSFTPClient,
            destination.driver.identity == driver.identity
        {
            try await copyOnSharedTransport(
                from: sourcePath, to: destinationPath, destination: destination,
                byteCount: byteCount, overwrite: overwrite,
                cancellation: cancellation, progress: progress)
            return
        }
        let relay = try SFTPSocketRelay()
        let observer = cancellation.observeCancellation { relay.stop() }
        defer {
            cancellation.removeObserver(observer)
            relay.close()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await self.downloadToSocket(
                        sourcePath, socket: relay.writer, cancellation: cancellation)
                    relay.finishWriting()
                } catch {
                    cancellation.cancel()
                    throw error
                }
            }
            group.addTask {
                try await destination.uploadStream(
                    fromSocket: relay.reader, to: destinationPath, byteCount: byteCount,
                    overwrite: overwrite, cancellation: cancellation, progress: progress,
                    sourceSucceeded: { relay.sourceSucceeded })
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
    }

    private func copyOnSharedTransport(
        from sourcePath: String, to destinationPath: String,
        destination: SSHSharedSFTPClient, byteCount: Int64, overwrite: Bool,
        cancellation: TransferCancellationToken,
        progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws {
        let source = try await openHandle(
            path: sourcePath, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
            type: Int32(LIBSSH2_SFTP_OPENFILE))
        var sourceOpen = true
        let identity = try await remoteIdentity(source)
        guard identity.byteCount == byteCount else {
            try? await closeHandle(source)
            throw SFTPResumeFailure.sourceChanged
        }
        let temporary = destinationPath + ".termind-copy-" + UUID().uuidString.lowercased()
        let output = try await destination.beginWrite(
            temporary: temporary, destination: destinationPath, overwrite: overwrite,
            continuing: false, snapshot: nil)
        do {
            var meter = SSHSharedSFTPProgressMeter(total: byteCount, report: progress)
            while let data = try await read(source, maximumBytes: 64 * 1024) {
                guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                guard Int64(data.count) <= byteCount - meter.completed else {
                    throw SFTPResumeFailure.sourceChanged
                }
                try await destination.write(
                    data, to: output.handle, cancellation: cancellation, acknowledge: nil)
                meter.add(data.count)
            }
            guard meter.completed == byteCount, try await remoteIdentity(source) == identity else {
                throw SFTPResumeFailure.sourceChanged
            }
            try await closeHandle(source)
            sourceOpen = false
            try await destination.closeHandle(SSHSharedSFTPHandle(output.handle))
            output.handleOpen = false
            if let existing = try await destination.attributes(at: destinationPath),
                !overwrite || existing.isDirectory
            {
                throw SFTPStreamUploadOperation.Failure.targetConflict
            }
            try await destination.rename(from: temporary, to: destinationPath, overwrite: overwrite)
            meter.finish()
        } catch {
            if sourceOpen { try? await closeHandle(source) }
            if output.handleOpen {
                try? await destination.closeHandle(SSHSharedSFTPHandle(output.handle))
            }
            try? await destination.removeFile(at: temporary)
            throw error
        }
    }

    private func downloadToSocket(
        _ path: String, socket: Int32, cancellation: TransferCancellationToken
    ) async throws {
        let handle = try await openHandle(
            path: path, flags: UInt(LIBSSH2_FXF_READ), mode: 0,
            type: Int32(LIBSSH2_SFTP_OPENFILE))
        do {
            while let data = try await read(handle, maximumBytes: 32_700) {
                var offset = 0
                while offset < data.count {
                    guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                    let sent = data.withUnsafeBytes {
                        Darwin.send(socket, $0.baseAddress!.advanced(by: offset), data.count - offset, 0)
                    }
                    if sent > 0 {
                        offset += sent
                    } else if sent < 0, errno == EINTR {
                        continue
                    } else {
                        throw SFTPError.operation("The SFTP copy relay was interrupted.")
                    }
                }
            }
            try await closeHandle(handle)
        } catch {
            try? await closeHandle(handle)
            throw error
        }
    }

    fileprivate func streamRead(
        _ handle: SSHSharedSFTPHandle, cancellation: TransferCancellationToken
    ) async throws -> Data? {
        guard !cancellation.isCancelled else { throw SFTPError.cancelled }
        return try await read(handle, maximumBytes: 64 * 1024)
    }

    fileprivate func streamSeek(_ handle: SSHSharedSFTPHandle, offset: Int64) async throws {
        guard offset >= 0 else { throw SFTPResumeFailure.partialChanged }
        try await seek(handle, offset: offset)
    }

    fileprivate func streamClose(_ handle: SSHSharedSFTPHandle) async throws {
        try await closeHandle(handle)
    }

    fileprivate func streamIdentity(_ handle: SSHSharedSFTPHandle) async throws -> SFTPSourceIdentity {
        try await remoteIdentity(handle)
    }

    private func openHandle(
        path: String, flags: UInt, mode: Int, type: Int32
    ) async throws -> SSHSharedSFTPHandle {
        try await driver.perform(id) { session, sftp in
            let opened = path.withCString {
                libssh2_sftp_open_ex(sftp, $0, UInt32(path.utf8.count), flags, mode, type)
            }
            if let opened { return .value(SSHSharedSFTPHandle(opened)) }
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN { return .again }
            throw Self.error(session, sftp, "Unable to open \(path)")
        }
    }

    private func closeHandle(_ handle: SSHSharedSFTPHandle) async throws {
        let _: Void = try await driver.perform(id) { session, sftp in
            let result = libssh2_sftp_close_handle(handle.pointer)
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            guard result == 0 else { throw Self.error(session, sftp, "Unable to close SFTP handle") }
            return .value(())
        }
    }

    private func read(_ handle: SSHSharedSFTPHandle, maximumBytes: Int) async throws -> Data? {
        try await driver.perform(id) { session, sftp in
            var buffer = [UInt8](repeating: 0, count: maximumBytes)
            let count = libssh2_sftp_read(handle.pointer, &buffer, buffer.count)
            if count == LIBSSH2_ERROR_EAGAIN { return .again }
            guard count >= 0 else { throw Self.error(session, sftp, "Unable to read remote file") }
            return .value(count == 0 ? nil : Data(buffer.prefix(count)))
        }
    }

    private func seek(_ handle: SSHSharedSFTPHandle, offset: Int64) async throws {
        let _: Void = try await driver.perform(id) { _, _ in
            libssh2_sftp_seek64(handle.pointer, UInt64(offset))
            return .value(())
        }
    }

    private func write(
        _ data: Data, to handle: OpaquePointer, cancellation: TransferCancellationToken?,
        acknowledge: ((Data) -> Void)?
    ) async throws {
        let stableHandle = SSHSharedSFTPHandle(handle)
        var position = 0
        while position < data.count {
            if cancellation?.isCancelled == true { throw SFTPError.cancelled }
            let start = position
            let written: Int = try await driver.perform(id) { session, sftp in
                let count = data.withUnsafeBytes {
                    libssh2_sftp_write(
                        stableHandle.pointer,
                        $0.baseAddress!.advanced(by: start).assumingMemoryBound(to: CChar.self),
                        data.count - start)
                }
                if count == LIBSSH2_ERROR_EAGAIN { return .again }
                guard count > 0 else { throw Self.error(session, sftp, "Unable to write remote file") }
                return .value(count)
            }
            let chunk = data.subdata(in: position..<(position + written))
            acknowledge?(chunk)
            position += written
        }
    }

    private func performStatus(
        prefix: String, _ operation: @escaping @Sendable (OpaquePointer) -> Int32
    ) async throws {
        let _: Void = try await driver.perform(id) { session, sftp in
            let result = operation(sftp)
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            guard result == 0 else { throw Self.error(session, sftp, prefix) }
            return .value(())
        }
    }

    private func beginWrite(
        temporary: String, destination: String, overwrite: Bool,
        continuing: Bool, snapshot: SFTPResumeState.Snapshot?
    ) async throws -> SSHSharedSFTPWriteContext {
        let flags = UInt(
            LIBSSH2_FXF_READ | LIBSSH2_FXF_WRITE
                | (continuing ? 0 : (LIBSSH2_FXF_CREAT | LIBSSH2_FXF_EXCL)))
        let context: SSHSharedSFTPWriteContext = try await driver.perform(id) { session, sftp in
            let handle = temporary.withCString {
                libssh2_sftp_open_ex(
                    sftp, $0, UInt32(temporary.utf8.count), flags, 0o600,
                    Int32(LIBSSH2_SFTP_OPENFILE))
            }
            if let handle {
                return .value(
                    SSHSharedSFTPWriteContext(
                        handle: handle, temporary: temporary,
                        destination: destination, overwrite: overwrite))
            }
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN { return .again }
            throw Self.error(session, sftp, "Unable to create \(destination)")
        }
        if continuing, let snapshot {
            guard try await remoteSize(SSHSharedSFTPHandle(context.handle)) == snapshot.offset else {
                try? await closeHandle(SSHSharedSFTPHandle(context.handle))
                throw SFTPResumeFailure.partialChanged
            }
            try await verifyRemotePrefix(
                SSHSharedSFTPHandle(context.handle), snapshot: snapshot,
                cancellation: TransferCancellationToken())
        }
        return context
    }

    private func finishWrite(_ context: SSHSharedSFTPWriteContext, resume: SFTPResumeState) async throws {
        guard try await remoteSize(SSHSharedSFTPHandle(context.handle)) == resume.snapshot.offset else {
            throw SFTPResumeFailure.partialChanged
        }
        try await closeHandle(SSHSharedSFTPHandle(context.handle))
        context.handleOpen = false
        if let existing = try await attributes(at: context.destination),
            !context.overwrite || existing.isDirectory
        {
            throw SFTPStreamUploadOperation.Failure.targetConflict
        }
        resume.willCommit()
        try await rename(
            from: context.temporary, to: context.destination,
            overwrite: context.overwrite)
        resume.didCommit()
    }

    private func remoteSize(_ handle: SSHSharedSFTPHandle) async throws -> Int64 {
        try await driver.perform(id) { session, sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = libssh2_sftp_fstat_ex(handle.pointer, &attributes, 0)
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            guard result == 0, attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0,
                attributes.filesize <= UInt64(Int64.max)
            else { throw Self.error(session, sftp, "Unable to inspect remote file") }
            return .value(Int64(attributes.filesize))
        }
    }

    private func remoteIdentity(_ handle: SSHSharedSFTPHandle) async throws -> SFTPSourceIdentity {
        try await driver.perform(id) { session, sftp in
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = libssh2_sftp_fstat_ex(handle.pointer, &attributes, 0)
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            guard result == 0, attributes.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0,
                attributes.filesize <= UInt64(Int64.max),
                attributes.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0,
                attributes.permissions & 0o170000 == 0o100000
            else { throw SFTPResumeFailure.sourceChanged }
            return .value(
                SFTPSourceIdentity(
                    byteCount: Int64(attributes.filesize),
                    modifiedAt: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
                        ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil))
        }
    }

    private func verifyRemotePrefix(
        _ handle: SSHSharedSFTPHandle, snapshot: SFTPResumeState.Snapshot,
        cancellation: TransferCancellationToken
    ) async throws {
        try await seek(handle, offset: 0)
        var remaining = snapshot.offset
        var digest = SHA256()
        while remaining > 0 {
            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
            guard let data = try await read(handle, maximumBytes: Int(min(remaining, 64 * 1024))),
                !data.isEmpty
            else { throw SFTPResumeFailure.partialChanged }
            digest.update(data: data)
            remaining -= Int64(data.count)
        }
        guard digest.finalize() == snapshot.digest.finalize() else {
            throw SFTPResumeFailure.partialChanged
        }
        try await seek(handle, offset: snapshot.offset)
    }

    private static func verifyLocalPrefix(
        _ file: FileHandle, snapshot: SFTPResumeState.Snapshot,
        cancellation: TransferCancellationToken
    ) throws {
        var remaining = snapshot.offset
        var digest = SHA256()
        while remaining > 0 {
            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
            let data = try file.read(upToCount: Int(min(remaining, 64 * 1024))) ?? Data()
            guard !data.isEmpty else { throw SFTPResumeFailure.partialChanged }
            digest.update(data: data)
            remaining -= Int64(data.count)
        }
        guard digest.finalize() == snapshot.digest.finalize() else {
            throw SFTPResumeFailure.partialChanged
        }
    }

    private static func localIdentity(_ url: URL) throws -> SFTPSourceIdentity {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw SFTPResumeFailure.sourceChanged
        }
        return SFTPSourceIdentity(byteCount: Int64(size), modifiedAt: values.contentModificationDate)
    }

    private static func error(
        _ session: OpaquePointer, _ sftp: OpaquePointer, _ prefix: String
    ) -> SFTPError {
        let sftpCode = libssh2_sftp_last_error(sftp)
        let sessionCode = libssh2_session_last_errno(session)
        let message = "\(prefix): SFTP error \(sftpCode)"
        if [UInt(LIBSSH2_FX_NO_CONNECTION), UInt(LIBSSH2_FX_CONNECTION_LOST)].contains(sftpCode)
            || [
                LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
                LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_CHANNEL_CLOSED,
            ].contains(sessionCode)
        {
            return .connectionLost(message)
        }
        return .operation(message)
    }

    private static func remoteFile(
        path: String, name: String? = nil, attributes: LIBSSH2_SFTP_ATTRIBUTES
    ) -> RemoteFile {
        let permissions = UInt32(attributes.permissions)
        let kind: RemoteFile.Kind
        switch permissions & 0o170000 {
        case 0o040000: kind = .directory
        case 0o100000: kind = .file
        case 0o120000: kind = .symbolicLink
        case 0: kind = .unknown
        default: kind = .special
        }
        return RemoteFile(
            path: path, name: name ?? URL(fileURLWithPath: path).lastPathComponent,
            kind: kind,
            size: attributes.filesize <= UInt64(Int64.max) ? Int64(attributes.filesize) : 0,
            modifiedAt: attributes.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0
                ? Date(timeIntervalSince1970: Double(attributes.mtime)) : nil,
            permissions: permissions, ownerUID: UInt32(attributes.uid), ownerGID: UInt32(attributes.gid))
    }
}

private actor SSHSharedSFTPDownloadStream: SFTPDownloadStream {
    private let client: SSHSharedSFTPClient
    private let handle: SSHSharedSFTPHandle
    let sourceIdentity: SFTPSourceIdentity?
    let byteCount: Int64
    private let cancellation: TransferCancellationToken
    private var closed = false
    private var received: Int64 = 0
    private var eof = false

    init(
        client: SSHSharedSFTPClient, handle: SSHSharedSFTPHandle,
        identity: SFTPSourceIdentity, cancellation: TransferCancellationToken
    ) {
        self.client = client
        self.handle = handle
        sourceIdentity = identity
        byteCount = identity.byteCount
        self.cancellation = cancellation
    }

    func seek(to offset: Int64) async throws {
        guard offset >= 0, offset <= byteCount else { throw SFTPResumeFailure.partialChanged }
        try await client.streamSeek(handle, offset: offset)
        received = offset
        eof = false
    }

    func readChunk() async throws -> Data? {
        guard !eof else { return nil }
        guard let data = try await client.streamRead(handle, cancellation: cancellation) else {
            guard received == byteCount,
                try await client.streamIdentity(handle) == sourceIdentity
            else { throw SFTPDownloadFailure.sourceChanged }
            eof = true
            return nil
        }
        guard Int64(data.count) <= byteCount - received else {
            throw SFTPDownloadFailure.sourceChanged
        }
        received += Int64(data.count)
        return data
    }

    func close() async throws {
        guard !closed else { return }
        closed = true
        try await client.streamClose(handle)
    }
}

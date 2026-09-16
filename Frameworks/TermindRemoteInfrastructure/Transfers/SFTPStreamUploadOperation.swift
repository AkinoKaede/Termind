import CryptoKit
import Darwin
import Foundation

/// A bounded byte source, independent of HTTP, local files, and agent workspaces.
public nonisolated enum SFTPStreamUploadOperation {
    public typealias ReadChunk = @Sendable () async throws -> Data?
    public static let chunkBytes = 64 * 1_024

    public enum Failure: Error, Sendable {
        case invalidLength, invalidChunk, targetConflict, missingParent, timedOut
        case digestMismatch(actualSHA256: String)
    }

    public static func run(
        client: any SFTPClientProtocol, remotePath: String, byteCount: Int64, sha256: String,
        overwrite: Bool, cancellation: TransferCancellationToken,
        idleTimeout: Duration = .seconds(60),
        read: @escaping ReadChunk, progress: @escaping @Sendable (SFTPProgress) -> Void
    ) async throws -> String {
        guard byteCount >= 0 else { throw Failure.invalidLength }
        let parent = (remotePath as NSString).deletingLastPathComponent
        guard try await client.attributes(at: parent)?.isDirectory == true else { throw Failure.missingParent }
        if let target = try await client.attributes(at: remotePath), target.isDirectory || !overwrite {
            throw Failure.targetConflict
        }
        let relay = try SFTPSocketRelay()
        let observer = cancellation.observeCancellation { relay.stop() }
        defer {
            cancellation.removeObserver(observer)
            relay.close()
        }
        let source = SourceState()
        let watchdog = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: min(.seconds(1), idleTimeout)) } catch { return }
                if source.idleDuration >= idleTimeout {
                    source.record(Failure.timedOut)
                    cancellation.cancel()
                    return
                }
            }
        }
        defer { watchdog.cancel() }
        let writerQueue = DispatchQueue(label: "termind.sftp.stream.source")
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask {
                        do {
                            var digest = SHA256()
                            var received: Int64 = 0
                            while let chunk = try await read() {
                                try Task.checkCancellation()
                                guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                                guard !chunk.isEmpty, chunk.count <= chunkBytes else { throw Failure.invalidChunk }
                                guard Int64(chunk.count) <= byteCount - received else { throw Failure.invalidLength }
                                received += Int64(chunk.count)
                                source.touch()
                                digest.update(data: chunk)
                                try await writerQueue.perform {
                                    try chunk.withUnsafeBytes { bytes in
                                        var offset = 0
                                        while offset < bytes.count {
                                            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
                                            let count = Darwin.send(
                                                relay.writer, bytes.baseAddress!.advanced(by: offset),
                                                bytes.count - offset, 0
                                            )
                                            if count > 0 {
                                                offset += count
                                            } else if count < 0 && errno == EINTR {
                                                continue
                                            } else {
                                                throw SFTPError.cancelled
                                            }
                                        }
                                    }
                                }
                            }
                            guard received == byteCount else { throw Failure.invalidLength }
                            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                            guard actual == sha256.lowercased() else {
                                throw Failure.digestMismatch(actualSHA256: actual)
                            }
                            relay.finishWriting()
                            return actual
                        } catch {
                            if !cancellation.isCancelled { source.record(error) }
                            cancellation.cancel()
                            throw error
                        }
                    }
                    group.addTask {
                        do {
                            try await client.uploadStream(
                                fromSocket: relay.reader, to: remotePath, byteCount: byteCount, overwrite: overwrite,
                                cancellation: cancellation,
                                progress: { value in
                                    source.touch()
                                    progress(value)
                                },
                                sourceSucceeded: { relay.sourceSucceeded }
                            )
                        } catch {
                            if let cleanup = error as? SFTPTemporaryFileCleanupError {
                                source.recordCleanup(cleanup.path)
                            }
                            throw error
                        }
                        return nil
                    }
                    var actual = ""
                    do {
                        while let result = try await group.next() { if let result { actual = result } }
                        return actual
                    } catch {
                        cancellation.cancel()
                        group.cancelAll()
                        throw error
                    }
                }
            } catch {
                if let path = source.cleanupPath {
                    let cleanup = error as? SFTPTemporaryFileCleanupError
                    throw SFTPTemporaryFileCleanupError(path: path, cause: source.failure ?? cleanup?.cause ?? error)
                }
                throw source.failure ?? error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private final class SourceState: @unchecked Sendable {
        private let lock = NSLock()
        private var error: (any Error)?
        private var remainingPath: String?
        var cleanupPath: String? { lock.withLock { remainingPath } }
        func recordCleanup(_ path: String) { lock.withLock { remainingPath = path } }
        private var lastProgress = ContinuousClock.now
        var idleDuration: Duration {
            lock.withLock { ContinuousClock.now - lastProgress }
        }
        func touch() { lock.withLock { lastProgress = .now } }
        var failure: (any Error)? { lock.withLock { error } }
        func record(_ error: any Error) { lock.withLock { if self.error == nil { self.error = error } } }
    }
}

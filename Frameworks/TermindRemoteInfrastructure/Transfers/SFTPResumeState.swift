import CryptoKit
import Foundation
import TermindApplication

/// Process-local state only. The digest covers acknowledged destination writes,
/// never bytes merely read from the source or queued on a socket.
public nonisolated final class SFTPResumeState: @unchecked Sendable {
    public struct Snapshot: Sendable {
        public var capturesFileVersion = false
        public var editPolicy: SFTPEditUploadPolicy?
        public var committedVersion: SFTPFileVersion?
        public var temporaryPath: String?
        public var offset: Int64 = 0
        public var digest = SHA256()
        public var source: SFTPSourceIdentity?
        public var hasTemporaryFile = false
        public var committed = false
        public var committing = false
        public var sha256: String { digest.finalize().map { String(format: "%02x", $0) }.joined() }
    }

    private let lock = NSLock()
    private var value = Snapshot()
    public init(editPolicy: SFTPEditUploadPolicy? = nil, capturesFileVersion: Bool = false) {
        value.editPolicy = editPolicy
        value.capturesFileVersion = capturesFileVersion
    }
    public var snapshot: Snapshot { lock.withLock { value } }

    func temporaryPath(for destination: String) -> String {
        lock.withLock {
            if let path = value.temporaryPath { return path }
            let path = destination + ".termind-part-" + UUID().uuidString
            value.temporaryPath = path
            return path
        }
    }

    public func validateSource(_ source: SFTPSourceIdentity) throws {
        try lock.withLock {
            if let previous = value.source, previous != source { throw SFTPResumeFailure.sourceChanged }
            value.source = source
        }
    }

    public func acknowledge(_ data: Data) {
        lock.withLock {
            value.digest.update(data: data)
            value.offset += Int64(data.count)
        }
    }

    func createdTemporaryFile() { lock.withLock { value.hasTemporaryFile = true } }
    public func recordPrefix(digest: SHA256, offset: Int64) {
        lock.withLock {
            if offset >= value.offset {
                value.digest = digest
                value.offset = offset
            }
        }
    }
    public func cleanup(using client: any SFTPClientProtocol) async throws {
        let current = snapshot
        guard !current.committed, let path = current.temporaryPath else { return }
        do {
            if try await client.attributes(at: path) != nil { try await client.removeFile(at: path) }
        } catch { throw SFTPTemporaryFileCleanupError(path: path, cause: error) }
    }

    func recordCommittedVersion(_ version: SFTPFileVersion) {
        lock.withLock { value.committedVersion = version }
    }

    func willCommit() { lock.withLock { value.committing = true } }
    func didCommit() { lock.withLock { value.committed = true } }
}

public nonisolated struct SFTPSourceIdentity: Equatable, Sendable {
    public var byteCount: Int64
    public var modifiedAt: Date?
    public init(byteCount: Int64, modifiedAt: Date?) {
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public nonisolated enum SFTPResumeFailure: LocalizedError, Sendable {
    case sourceChanged, partialChanged, unsupported
    public var errorDescription: String? {
        switch self {
        case .sourceChanged: String(localized: "The source file changed. Start a new transfer.")
        case .partialChanged: String(localized: "The incomplete file changed. Start a new transfer.")
        case .unsupported: String(localized: "This connection does not support resuming transfers.")
        }
    }
}

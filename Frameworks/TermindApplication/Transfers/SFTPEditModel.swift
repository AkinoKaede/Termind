import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

/// Metadata is a best-effort concurrency guard, not a server-side compare-and-swap.
public nonisolated struct SFTPFileVersion: Equatable, Sendable {
    public let kind: RemoteFile.Kind
    public let size: Int64
    public let modifiedAt: Date?
    public let permissions: UInt32

    public init(_ file: RemoteFile) {
        kind = file.kind
        size = file.size
        modifiedAt = file.modifiedAt
        permissions = file.permissionMode
    }
}

public nonisolated struct SFTPEditUploadPolicy: Sendable {
    public let expected: SFTPFileVersion?
    public let permissions: UInt32

    public init(expected: SFTPFileVersion?, permissions: UInt32) {
        self.expected = expected
        self.permissions = permissions
    }

    public func validate(_ file: RemoteFile?) throws {
        guard file.map(SFTPFileVersion.init) == expected,
            file == nil || file?.kind == .file
        else { throw SFTPEditFailure.remoteChanged }
    }
}

public nonisolated enum SFTPEditFailure: LocalizedError, Sendable {
    case remoteChanged, unavailable, localChanged, unsupported

    public var errorDescription: String? {
        switch self {
        case .remoteChanged: String(localized: "The remote file changed. Review it before uploading again.")
        case .unavailable: String(localized: "The original connection is no longer available.")
        case .localChanged: String(localized: "The local file changed while preparing the upload. Try again.")
        case .unsupported: String(localized: "This file cannot be uploaded back to its original path.")
        }
    }
}

public nonisolated struct SFTPEditedFile: Identifiable, Sendable {
    public let id: UUID
    public let hostID: Host.ID
    public let remotePath: String
    public let localURL: URL
    public var baseline: SFTPFileVersion
    public var uploadedDigest: String
    public var currentDigest: String
    public var isPreparing = false
    public var transferID: UUID?
    public var error: String?
    public var localError: String?
    public var isInvalidated = false
    public var name: String { localURL.lastPathComponent }
    public var isModified: Bool { currentDigest != uploadedDigest }
    public var displayedError: String? { error ?? localError }
    public var isVisible: Bool { isModified || isPreparing || transferID != nil }
}

/// Process-local edit records outlive individual browsers and workspaces.
@MainActor
@Observable
public final class SFTPEditModel {
    public private(set) var files: [SFTPEditedFile] = []
    public init() {}

    public var hasPendingChanges: Bool { files.contains(where: \.isVisible) }

    public func modifiedFiles(for hostID: Host.ID) -> [SFTPEditedFile] {
        files.filter { $0.hostID == hostID && $0.isVisible }
    }

    public func file(_ id: UUID) -> SFTPEditedFile? { files.first { $0.id == id } }

    public func file(hostID: Host.ID, path: String) -> SFTPEditedFile? {
        files.first { $0.hostID == hostID && $0.remotePath == path }
    }

    @discardableResult
    public func register(hostID: Host.ID, file: RemoteFile, localURL: URL, digest: String) -> UUID {
        if let existing = self.file(hostID: hostID, path: file.path) { return existing.id }
        let id = UUID()
        files.append(
            SFTPEditedFile(
                id: id, hostID: hostID, remotePath: file.path, localURL: localURL,
                baseline: SFTPFileVersion(file), uploadedDigest: digest, currentDigest: digest))
        return id
    }

    public func update(_ id: UUID, _ change: (inout SFTPEditedFile) -> Void) {
        guard let index = files.firstIndex(where: { $0.id == id }) else { return }
        change(&files[index])
    }

    public func remove(_ id: UUID) { files.removeAll { $0.id == id } }

    public func didUpload(_ id: UUID, digest: String, baseline: SFTPFileVersion) {
        update(id) {
            $0.uploadedDigest = digest
            $0.baseline = baseline
            $0.transferID = nil
            $0.isPreparing = false
            $0.error = nil
        }
    }

    public func invalidate(hostID: Host.ID) {
        for index in files.indices where files[index].hostID == hostID {
            files[index].isInvalidated = true
            files[index].error = SFTPEditFailure.unavailable.localizedDescription
        }
    }
}

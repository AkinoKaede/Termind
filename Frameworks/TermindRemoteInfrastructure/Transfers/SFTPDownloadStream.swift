// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A checked regular-file handle. EOF proves the declared size and available
/// modification metadata still match; it does not promise an atomic snapshot.
public nonisolated protocol SFTPDownloadStream: Sendable {
    var byteCount: Int64 { get }
    var sourceIdentity: SFTPSourceIdentity? { get }
    func seek(to offset: Int64) async throws
    func readChunk() async throws -> Data?
    func close() async throws
}

public nonisolated enum SFTPDownloadFailure: Error, Sendable {
    case missingFile, unsupportedType, tooLarge, sourceChanged, invalidChunk, closeFailed, timedOut
    case digestMismatch(actualSHA256: String)
}

nonisolated extension SFTPDownloadStream {
    public var sourceIdentity: SFTPSourceIdentity? { nil }
    public func seek(to offset: Int64) async throws { throw SFTPResumeFailure.unsupported }
}

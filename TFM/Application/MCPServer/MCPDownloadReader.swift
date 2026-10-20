// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import CryptoKit
import Foundation
import TermindRemoteInfrastructure

actor MCPDownloadReader {
    let stream: any SFTPDownloadStream
    let expectedSHA256: String?
    let cancellation: TransferCancellationToken
    let resume: SFTPResumeState?
    private var digest = SHA256()
    private var received: Int64 = 0
    private var sent: Int64 = 0
    private var eof = false
    private var lastProgress = ContinuousClock.now
    private(set) var actualSHA256: String?
    var idleDuration: Duration { ContinuousClock.now - lastProgress }

    init(
        stream: any SFTPDownloadStream, expectedSHA256: String?, cancellation: TransferCancellationToken,
        resume: SFTPResumeState? = nil
    ) {
        self.stream = stream
        self.expectedSHA256 = expectedSHA256
        self.cancellation = cancellation
        self.resume = resume
    }
    /// Verify the previous attempt's prefix before publishing HTTP headers.
    /// Rehashing is bounded and also reconstructs the full-file digest for Range.
    func prepare(offset: Int64) async throws {
        guard let resume else { return }
        try resume.validateSource(
            stream.sourceIdentity ?? SFTPSourceIdentity(byteCount: stream.byteCount, modifiedAt: nil))
        let previous = resume.snapshot
        let end = max(offset, previous.offset)
        var checked: Int64 = 0
        var hash = SHA256()
        var prefix = SHA256()
        while checked < end {
            try Task.checkCancellation()
            guard !cancellation.isCancelled else { throw SFTPError.cancelled }
            guard let chunk = try await stream.readChunk(), !chunk.isEmpty, chunk.count <= 64 * 1024 else {
                throw SFTPResumeFailure.sourceChanged
            }
            var index = 0
            while index < chunk.count && checked < end {
                let boundary = [offset, previous.offset, end].filter { $0 > checked }.min()!
                let count = Int(min(Int64(chunk.count - index), boundary - checked))
                hash.update(data: chunk.subdata(in: index..<(index + count)))
                checked += Int64(count)
                index += count
                if checked == offset { prefix = hash }
                if checked == previous.offset, hash.finalize() != previous.digest.finalize() {
                    throw SFTPResumeFailure.sourceChanged
                }
            }
            lastProgress = .now
        }
        if end > 0 { try await stream.seek(to: offset) }
        digest = prefix
        received = offset
        sent = offset
        resume.recordPrefix(digest: hash, offset: end)
    }

    func readChunk() async throws -> Data? {
        try Task.checkCancellation()
        guard !cancellation.isCancelled else { throw AgentToolError.cancelled }
        guard !eof else { return nil }
        if let chunk = try await stream.readChunk() {
            guard !chunk.isEmpty, chunk.count <= 64 * 1_024 else { throw SFTPDownloadFailure.invalidChunk }
            guard Int64(chunk.count) <= stream.byteCount - received else { throw SFTPDownloadFailure.sourceChanged }
            received += Int64(chunk.count)
            digest.update(data: chunk)
            resume?.recordPrefix(digest: digest, offset: received)
            lastProgress = .now
            return chunk
        }
        guard received == stream.byteCount else { throw SFTPDownloadFailure.sourceChanged }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        actualSHA256 = actual
        eof = true
        if let expectedSHA256, actual != expectedSHA256 {
            throw SFTPDownloadFailure.digestMismatch(actualSHA256: actual)
        }
        return nil
    }
    func didSend(_ count: Int) -> Int64 {
        sent += Int64(count)
        lastProgress = .now
        return sent
    }
    func validateCompletion() throws {
        guard eof, received == stream.byteCount, sent == received, actualSHA256 != nil else {
            throw SFTPDownloadFailure.sourceChanged
        }
    }
}

/// Two one-shot handshakes: a checked source is ready, then HTTP has finished.
/// The dedicated SFTP task waits for the latter before closing its lease.
actor MCPDownloadExchange {
    private var ready: HTTPResponse?
    private var published = false
    private var readyWaiter: CheckedContinuation<HTTPResponse, Never>?
    private var completion: Result<Void, any Error>?
    private var completionWaiter: CheckedContinuation<Void, any Error>?
    func publish(_ response: HTTPResponse) {
        guard !published else { return }
        published = true
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.resume(returning: response)
        } else {
            ready = response
        }
    }
    func response() async -> HTTPResponse {
        if let ready {
            self.ready = nil
            return ready
        }
        return await withCheckedContinuation { readyWaiter = $0 }
    }
    func complete(_ result: Result<Void, any Error>) {
        guard completion == nil else { return }
        completion = result
        completionWaiter?.resume(with: result)
        completionWaiter = nil
    }
    func waitForCompletion() async throws {
        if let completion { return try completion.get() }
        try await withCheckedThrowingContinuation { completionWaiter = $0 }
    }
}

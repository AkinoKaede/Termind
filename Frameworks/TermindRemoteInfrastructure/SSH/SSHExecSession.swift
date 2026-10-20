// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication

/// Controls one non-PTY exec channel, independently of the pooled connection.
nonisolated public final class SSHExecSession: @unchecked Sendable {
    public typealias Writer = @Sendable (SSHCommandInput?) async throws -> Int
    public let keepsStdinOpen: Bool
    public let cancellation = TransferCancellationToken()
    private let lock = NSLock()
    private var startup: Result<Void, any Error>?
    private var waiter: CheckedContinuation<Void, any Error>?
    private var writer: Writer?
    private var closed: Bool
    private var didStart = false

    public init(keepsStdinOpen: Bool) {
        self.keepsStdinOpen = keepsStdinOpen
        closed = !keepsStdinOpen
    }

    public var started: Bool { lock.withLock { didStart } }
    public var stdinClosed: Bool { lock.withLock { closed } }

    public func waitUntilStarted() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, any Error>? = lock.withLock {
                if let startup { return startup }
                waiter = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    public func start(writer: @escaping Writer) {
        resolveStartup(.success(()), writer: writer)
    }

    public func finish(error: (any Error)? = nil) {
        resolveStartup(.failure(error ?? CancellationError()), writer: nil)
        lock.withLock {
            writer = nil
            closed = true
        }
    }

    private func resolveStartup(_ result: Result<Void, any Error>, writer: Writer?) {
        let continuation = lock.withLock {
            guard startup == nil else { return Optional<CheckedContinuation<Void, any Error>>.none }
            startup = result
            self.writer = writer
            if case .success = result { didStart = true }
            defer { waiter = nil }
            return waiter
        }
        continuation?.resume(with: result)
    }

    public func write(_ input: SSHCommandInput?) async throws -> Int {
        let writer = try lock.withLock {
            if closed {
                if input == nil { return Optional<Writer>.none }
                throw TermindSSHError.library("Command input is closed.")
            }
            guard let writer else { throw TermindSSHError.library("Command input is unavailable.") }
            return writer
        }
        guard let writer else { return 0 }
        let count = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await writer(input)
        } onCancel: {
            self.cancellation.cancel()
        }
        if input == nil { lock.withLock { closed = true } }
        return count
    }
}

/// Byte-bounded UTF-8 tail. Drop an incomplete leading scalar, never split a valid one.
nonisolated enum SSHOutputTail {
    @discardableResult
    static func append(_ chunk: Data, to data: inout Data, limit: Int) -> Bool {
        data.append(chunk)
        guard data.count > max(0, limit) else { return false }
        data = Data(data.suffix(max(0, limit)))
        while let first = data.first, first & 0xC0 == 0x80 { data.removeFirst() }
        return true
    }
}

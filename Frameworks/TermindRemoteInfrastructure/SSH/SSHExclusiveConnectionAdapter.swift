// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Lifecycle and admission adapter for features that deliberately own one SSH
/// connection and serialize operations on it. It has no topology selection or
/// fallback policy; callers that need concurrency use `SSHChannelSchedulingMode`.
public actor SSHExclusiveConnectionAdapter<Connection: Sendable> {
    public nonisolated let connection: Connection
    private let close: @Sendable (Connection) async -> Void
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(connection: Connection, close: @escaping @Sendable (Connection) async -> Void) {
        self.connection = connection
        self.close = close
    }

    /// Serializes short-lived sessions such as Metrics exec requests.
    public func withConnection<Value: Sendable>(
        _ operation: @escaping @Sendable (Connection) async throws -> Value
    ) async throws -> Value {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        }
        busy = true
        defer {
            if waiters.isEmpty {
                busy = false
            } else {
                waiters.removeFirst().resume()
            }
        }
        return try await operation(connection)
    }

    public func disconnect() async { await close(connection) }
}

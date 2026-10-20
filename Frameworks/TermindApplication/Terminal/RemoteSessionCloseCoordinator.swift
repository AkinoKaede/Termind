// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated struct RemoteSessionCloseRequest: Sendable {
    public let reference: RemoteSessionReference
    public let snapshot: SSHAdditionalConnectionSnapshot
    public let connection: RemoteSessionCloseConnection?

    public init(
        reference: RemoteSessionReference, snapshot: SSHAdditionalConnectionSnapshot,
        connection: RemoteSessionCloseConnection? = nil
    ) {
        self.reference = reference
        self.snapshot = snapshot
        self.connection = connection
    }
}

/// A transferred connection has exactly one cleanup owner, even after cancellation or deduplication.
public actor RemoteSessionCloseConnection {
    private let prepare: @Sendable () async throws -> RemoteSessionCommandExecutor
    private let release: @Sendable () async -> Void
    private var released = false

    public init(
        prepare: @escaping @Sendable () async throws -> RemoteSessionCommandExecutor,
        release: @escaping @Sendable () async -> Void
    ) {
        self.prepare = prepare
        self.release = release
    }

    public func executor() async throws -> RemoteSessionCommandExecutor {
        guard !released else { throw TermindSSHError.disconnected }
        return try await prepare()
    }

    public func disconnect() async {
        guard !released else { return }
        released = true
        await release()
    }
}

/// Owns one-shot cleanup independently of the workspace and its terminal transport.
@MainActor
public final class RemoteSessionCloseCoordinator {
    public typealias Terminate = @MainActor (RemoteSessionCloseRequest) async throws -> Void

    private struct Pending {
        let reference: RemoteSessionReference
        let task: Task<Void, Never>
    }
    public var isClosing: Bool { !pending.isEmpty }

    private var pending: [UUID: Pending] = [:]
    private let terminate: Terminate
    private let timeout: Duration

    public init(timeout: Duration = .seconds(30), terminate: @escaping Terminate) {
        self.timeout = timeout
        self.terminate = terminate
    }

    deinit {
        for entry in pending.values { entry.task.cancel() }
    }

    @discardableResult
    public func enqueue(
        _ request: RemoteSessionCloseRequest, intent: TerminalTeardownIntent = .explicitClose
    ) -> Bool {
        guard intent.endsManagedSession, request.reference.isManaged else {
            if let connection = request.connection { Task { await connection.disconnect() } }
            return false
        }
        if pending.values.contains(where: { $0.reference.hasSameIdentity(as: request.reference) }) {
            if let connection = request.connection { Task { await connection.disconnect() } }
            return true
        }
        let id = UUID()
        let task = Task { [weak self, terminate, timeout] in
            let operation = Task {
                try Task.checkCancellation()
                try await terminate(request)
            }
            let deadline = Task {
                try await Task.sleep(for: timeout)
                operation.cancel()
            }
            defer { deadline.cancel() }
            await withTaskCancellationHandler {
                _ = try? await operation.value
            } onCancel: {
                operation.cancel()
            }
            await request.connection?.disconnect()
            self?.pending[id] = nil
        }
        pending[id] = Pending(reference: request.reference, task: task)
        return true
    }

    public func cancelAll() {
        for entry in pending.values { entry.task.cancel() }
    }

    public func waitUntilIdle() async {
        for entry in Array(pending.values) { await entry.task.value }
    }
}

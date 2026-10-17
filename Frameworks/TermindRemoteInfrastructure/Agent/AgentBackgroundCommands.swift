import AgentKit
import Foundation
import TermindApplication

/// Owns the identical timer lifecycle shared by idle registries. Each owning
/// actor still decides what is idle and when an empty registry should stop it.
nonisolated public final class AgentIdleSweeper: @unchecked Sendable {
    private let interval: Duration?
    private var task: Task<Void, Never>?

    public init(interval: Duration?) { self.interval = interval }

    public func start(sweep: @escaping @Sendable () async -> Int) {
        guard task == nil, let interval else { return }
        task = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard await sweep() > 0 else { return }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}

/// Conversation/session-scoped commands, including starts that are still authenticating.
/// Running commands never expire. Finished results expire from completion, not from last read.
public actor AgentBackgroundCommands {
    private struct Entry {
        let scope: UUID
        let hostID: UUID
        let command: String
        let startedAt: Date
        let session: SSHExecSession
        let stream: AgentCommandOutputStream
        let task: Task<Void, Never>
        let completion: AgentCompletionSignal
        var result: Result<SSHExecResult, any Error>?
        var finishedAt: Date?
        var completedAt: ContinuousClock.Instant?
    }

    private var entries: [UUID: Entry] = [:]
    private let retention: Duration
    private let sweeper: AgentIdleSweeper

    public init(idleTimeout: Duration = .seconds(600), sweepInterval: Duration? = .seconds(60)) {
        retention = idleTimeout
        sweeper = AgentIdleSweeper(interval: sweepInterval)
    }

    public var count: Int { entries.count }

    public func start(
        scope: UUID, hostID: UUID, command: String, keepsStdinOpen: Bool,
        stream: AgentCommandOutputStream,
        operation: @escaping @Sendable (SSHExecSession) async throws -> SSHExecResult
    ) async throws -> UUID {
        try Task.checkCancellation()
        let handle = UUID()
        let session = SSHExecSession(keepsStdinOpen: keepsStdinOpen)
        let task = Task {
            let result: Result<SSHExecResult, any Error>
            do { result = .success(try await operation(session)) } catch { result = .failure(error) }
            self.complete(handle, result: result)
            switch result {
            case .success: session.finish()
            case .failure(let error): session.finish(error: error)
            }
        }
        entries[handle] = Entry(
            scope: scope, hostID: hostID, command: command, startedAt: .now,
            session: session, stream: stream, task: task, completion: AgentCompletionSignal())
        sweeper.start { [weak self] in await self?.sweepIdle() ?? 0 }
        do {
            try await withTaskCancellationHandler {
                try await session.waitUntilStarted()
                try Task.checkCancellation()
            } onCancel: {
                task.cancel()
                session.cancellation.cancel()
                session.finish(error: CancellationError())
            }
            _ = try entry(handle, scope: scope)
            return handle
        } catch {
            entries.removeValue(forKey: handle)
            stopSweepingIfEmpty()
            throw error
        }
    }

    private func complete(_ handle: UUID, result: Result<SSHExecResult, any Error>) {
        guard var entry = entries[handle] else { return }
        entry.result = result
        entry.finishedAt = .now
        entry.completedAt = .now
        entries[handle] = entry
        entry.completion.signal()
    }

    public func waitForCompletion(
        _ handle: UUID, scope: UUID, interjection: (@Sendable () async -> Void)? = nil
    ) async throws {
        let completion = try entry(handle, scope: scope).completion
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await completion.wait() }
            if let interjection { group.addTask { await interjection() } }
            _ = await group.next()
            group.cancelAll()
        }
        try Task.checkCancellation()
    }

    public func command(_ handle: UUID, scope: UUID) throws -> (hostID: UUID, command: String) {
        let entry = try entry(handle, scope: scope)
        return (entry.hostID, entry.command)
    }

    public func output(_ handle: UUID, scope: UUID) throws -> AgentJSONValue {
        let entry = try entry(handle, scope: scope)
        var fields = metadata(handle, entry)
        fields.removeValue(forKey: "command")
        fields.removeValue(forKey: "started_at")
        fields.removeValue(forKey: "finished_at")
        let output = entry.stream.captured
        fields["stdout"] = .string(output.standardOut)
        fields["stderr"] = .string(output.standardError)
        return .object(fields)
    }

    public func write(_ handle: UUID, scope: UUID, input: SSHCommandInput?) async throws -> AgentJSONValue {
        let session = try entry(handle, scope: scope).session
        let count = try await session.write(input)
        return .object([
            "handle": .string(handle.uuidString), "status": .string(input == nil ? "closed" : "written"),
            "bytes_written": .number(Double(count)), "stdin_closed": .bool(session.stdinClosed),
        ])
    }

    public func cancel(_ handle: UUID, scope: UUID) throws -> AgentJSONValue {
        let entry = try entry(handle, scope: scope)
        entries[handle] = nil
        let running = entry.result == nil
        entry.completion.signal()
        entry.task.cancel()
        entry.session.cancellation.cancel()
        entry.session.finish(error: CancellationError())
        stopSweepingIfEmpty()
        return .object([
            "handle": .string(handle.uuidString), "status": .string(running ? "cancelled" : "released"),
            "was_running": .bool(running), "remote_termination_confirmed": .bool(false),
        ])
    }

    public func list(scope: UUID, hostID: UUID? = nil, includeFinished: Bool = false) -> AgentJSONValue {
        sweepIdle()
        let commands = entries.filter {
            $0.value.scope == scope && $0.value.session.started
                && (hostID == nil || $0.value.hostID == hostID)
                && (includeFinished || $0.value.result == nil)
        }.sorted {
            $0.value.startedAt == $1.value.startedAt
                ? $0.key.uuidString < $1.key.uuidString : $0.value.startedAt > $1.value.startedAt
        }.map { AgentJSONValue.object(metadata($0.key, $0.value)) }
        return .object(["commands": .array(commands)])
    }

    public func hasActivity(scope: UUID) -> Bool {
        entries.values.contains { $0.scope == scope && $0.result == nil }
    }

    public func close(scope: UUID) {
        for (id, entry) in entries where entry.scope == scope {
            entry.completion.signal()
            entry.task.cancel()
            entry.session.cancellation.cancel()
            entry.session.finish(error: CancellationError())
            entries[id] = nil
        }
        stopSweepingIfEmpty()
    }

    public func closeAll() {
        for entry in entries.values {
            entry.completion.signal()
            entry.task.cancel()
            entry.session.cancellation.cancel()
            entry.session.finish(error: CancellationError())
        }
        entries.removeAll()
        stopSweepingIfEmpty()
    }

    @discardableResult
    public func sweepIdle(now: ContinuousClock.Instant = .now) -> Int {
        entries = entries.filter { _, entry in
            guard let completed = entry.completedAt else { return true }
            return now - completed < retention
        }
        stopSweepingIfEmpty()
        return entries.count
    }

    private func entry(_ handle: UUID, scope: UUID) throws -> Entry {
        sweepIdle()
        guard let entry = entries[handle], entry.scope == scope, entry.session.started else {
            throw AgentBackgroundCommandError.unknownHandle
        }
        return entry
    }

    private func metadata(_ handle: UUID, _ entry: Entry) -> [String: AgentJSONValue] {
        var status = "running"
        var code: AgentJSONValue = .null
        var signal: AgentJSONValue = .null
        var error: AgentJSONValue = .null
        switch entry.result {
        case .success(let result):
            status = "exited"
            code = .number(Double(result.exitCode))
            signal = result.signal.map(AgentJSONValue.string) ?? .null
        case .failure(let failure):
            status = "failed"
            error = .string(failure.localizedDescription)
        case nil: break
        }
        return [
            "handle": .string(handle.uuidString), "host_id": .string(entry.hostID.uuidString),
            "command": .string(entry.command), "status": .string(status),
            "started_at": .string(entry.startedAt.ISO8601Format()),
            "finished_at": entry.finishedAt.map { .string($0.ISO8601Format()) } ?? .null,
            "exit_code": code, "signal": signal, "error": error,
            "stdin_closed": .bool(entry.result != nil || entry.session.stdinClosed),
        ]
    }

    private func stopSweepingIfEmpty() {
        if entries.isEmpty { sweeper.stop() }
    }
}

/// A one-shot arrival bell whose wait can be abandoned.
///
/// `Task.result` cannot be given up on, which is the whole difficulty: waiting
/// for a command has to be interruptible even though the command is not.
nonisolated public final class AgentCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasArrived = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public func signal() {
        let pending = lock.withLock {
            hasArrived = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in pending { waiter.resume() }
    }

    public func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let arrived: Bool = lock.withLock {
                    if hasArrived || Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if arrived { continuation.resume() }
            }
        } onCancel: {
            // Releases the waiter without claiming the thing arrived: giving up
            // on a wait is not the same event as the command finishing.
            let resume: CheckedContinuation<Void, Never>? = lock.withLock {
                waiters.removeValue(forKey: id)
            }
            resume?.resume()
        }
    }
}

nonisolated public enum AgentBackgroundCommandError: LocalizedError, Sendable {
    case unknownHandle
    public var errorDescription: String? { "Unknown or expired command handle in this session." }
}

import Foundation
import TermindApplication

/// What a command looks like to whoever asked about it.
///
/// One shape for both answers, because a caller that has to branch on which
/// kind of reply it got is a caller that will forget to. `exitCode` is `nil`
/// exactly when the command is still running.
nonisolated public struct AgentCommandOutcome: Sendable {
    public var handle: UUID
    public var standardOut: String
    public var standardError: String
    public var exitCode: Int32?
    public var signal: String?
    public var isRunning: Bool { exitCode == nil }

    public init(handle: UUID, standardOut: String, standardError: String, exitCode: Int32? = nil, signal: String? = nil)
    {
        self.handle = handle
        self.standardOut = standardOut
        self.standardError = standardError
        self.exitCode = exitCode
        self.signal = signal
    }
}

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

/// Commands that outlived the turn that started them.
///
/// A tool returns when it decides to, which for `ssh_exec` means reporting what
/// it has rather than blocking a whole turn on a fifteen-minute deploy. The
/// command keeps running on its own session lease, its output keeps arriving on
/// the card, and this is where the model comes back for the rest of it. The
/// authenticated connection remains in the Agent pool and can carry peers.
///
/// Owned by `AppModel` rather than by a run, because the point is to outlive
/// one: a handle taken in one turn is answered in a later one, and a run that
/// ends is not a reason to stop a deploy.
///
/// There is deliberately no "kill". Closing a session does not prove that the
/// process on the far side stopped, so a tool by that name would promise what
/// it cannot do. `sweepIdle` cancels the local task and retires only its session.
public actor AgentBackgroundCommands {
    /// Long enough that a model which meant to come back gets the chance, short
    /// enough that a forgotten `tail -f` does not hold a session open all day.
    public static let defaultIdleTimeout = Duration.seconds(600)

    private struct Entry {
        let stream: AgentCommandOutputStream
        let task: Task<SSHExecResult, any Error>
        var lastAskedAt: ContinuousClock.Instant
    }

    private var entries: [UUID: Entry] = [:]
    private let idleTimeout: Duration
    /// `nil` disables the timer, for tests that drive `sweepIdle` themselves
    /// with a synthetic instant. Same seam, and same reason, as the connection
    /// pool's.
    private let sweeper: AgentIdleSweeper

    public init(
        idleTimeout: Duration = AgentBackgroundCommands.defaultIdleTimeout,
        sweepInterval: Duration? = .seconds(60)
    ) {
        self.idleTimeout = idleTimeout
        sweeper = AgentIdleSweeper(interval: sweepInterval)
    }

    public var count: Int { entries.count }

    /// Takes ownership of a command still in flight. Its task retains exactly
    /// one session lease; the connection pool retains the shared connection.
    public func adopt(
        stream: AgentCommandOutputStream,
        task: Task<SSHExecResult, any Error>,
        now: ContinuousClock.Instant = .now
    ) -> UUID {
        let handle = UUID()
        entries[handle] = Entry(stream: stream, task: task, lastAskedAt: now)
        startSweeping()
        return handle
    }

    /// Waits up to `timeout` for the command behind `handle` to finish.
    ///
    /// Returns what it has either way. A wait that expires is not an error and
    /// not a failure of the command — it is the same answer `ssh_exec` gave in
    /// the first place, and the handle stays valid for another ask.
    public func wait(
        _ handle: UUID, timeout: Duration,
        reporting: (@Sendable (String, String) -> Void)? = nil,
        orWhen interjection: (@Sendable () async -> Void)? = nil,
        now: ContinuousClock.Instant = .now
    ) async throws -> AgentCommandOutcome {
        guard var entry = entries[handle] else { throw AgentBackgroundCommandError.unknownHandle }
        entry.lastAskedAt = now
        entries[handle] = entry
        // The output belongs under whichever call is answering for it, and from
        // here that is this one: the `ssh_exec` that started the command has
        // returned, and its progress gate is shut.
        if let reporting { entry.stream.redirect(to: reporting) }

        guard await Self.settled(entry.task, within: timeout, orWhen: interjection) else {
            let captured = entry.stream.captured
            return AgentCommandOutcome(
                handle: handle, standardOut: captured.standardOut,
                standardError: captured.standardError, exitCode: nil
            )
        }

        // Finished, so the handle is done. The task already released its
        // session; the shared connection returns to the Agent pool's idle clock.
        entries.removeValue(forKey: handle)
        stopSweepingIfEmpty()
        let result = try await entry.task.value
        return AgentCommandOutcome(
            handle: handle, standardOut: result.stdout, standardError: result.stderr,
            exitCode: result.exitCode, signal: result.signal
        )
    }

    /// Lets go of anything nobody has asked about within the idle window, and
    /// reports how many are left. Driven by the app, and called directly with a
    /// synthetic instant by tests — the same shape as `AgentConnectionPool`.
    @discardableResult
    public func sweepIdle(now: ContinuousClock.Instant = .now) async -> Int {
        let expired = entries.filter { now - $0.value.lastAskedAt >= idleTimeout }
        for (handle, entry) in expired {
            entries.removeValue(forKey: handle)
            entry.task.cancel()
        }
        stopSweepingIfEmpty()
        return entries.count
    }

    public func closeAll() async {
        let closing = entries.values
        entries.removeAll()
        stopSweepingIfEmpty()
        for entry in closing {
            entry.task.cancel()
        }
    }

    /// Runs only while something is held. A timer ticking against an empty
    /// registry is a wakeup a laptop pays for and nobody reads.
    private func startSweeping() {
        sweeper.start { [weak self] in
            guard let self else { return 0 }
            return await self.sweepIdle(now: .now)
        }
    }

    private func stopSweepingIfEmpty() {
        guard entries.isEmpty else { return }
        sweeper.stop()
    }

    /// Whether the task settled inside the window, without cancelling it when
    /// it did not — the command is meant to outlive the wait.
    ///
    /// Shared with `ssh_exec`, whose first wait is the same question asked with
    /// a shorter deadline.
    ///
    /// The watcher is unstructured for a reason worth stating, because the
    /// obvious version deadlocks: a task group awaits every child before it
    /// returns, and `await task.result` ignores cancellation, so a child
    /// watching a command that outlives the deadline pins the group open until
    /// the command ends — which is precisely the case this exists to escape.
    /// Nothing may await the watcher. It outlives this call by design, ends
    /// when the command does, and signals into a gate that by then has no
    /// listener.
    public static func settled<T>(
        _ task: Task<T, any Error>, within timeout: Duration,
        orWhen interjection: (@Sendable () async -> Void)? = nil
    ) async -> Bool {
        let arrival = AgentCompletionSignal()
        Task {
            _ = await task.result
            arrival.signal()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await arrival.wait()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            if let interjection {
                // Reported the same way a deadline is, because to the caller it
                // is the same answer: not finished yet, ask again. Nothing is
                // cancelled and nothing is lost by stopping here.
                group.addTask {
                    await interjection()
                    return false
                }
            }
            let first = await group.next() ?? false
            // Both children answer to cancellation — the sleeper by throwing,
            // the waiter through its cancellation handler — so the group drains
            // rather than waiting on the command.
            group.cancelAll()
            return first
        }
    }
}

/// Decides once, for one command, whether it got far enough to be handed on.
///
/// Connecting is inside the deadline, because a hang is a hang whether it is
/// DNS, a jump host or a handshake, and a turn that ends on time is the whole
/// point. But a command that never started is not something there is anything
/// to hand over — no session, no output, no handle worth giving — so the two
/// outcomes have to be told apart, and told apart *once*: the call giving up
/// and the command starting can happen at the same instant, and exactly one of
/// them must win.
nonisolated public final class AgentCommandHandover: @unchecked Sendable {
    private enum State {
        case connecting
        case running
        case abandoned
    }

    private let lock = NSLock()
    private var state = State.connecting

    /// The command is about to start. `false` means the call already gave up
    /// while the connection was still being made, so it must not start at all —
    /// a command nobody holds a handle to would run, print, and finish unseen.
    public func beginRunning() -> Bool {
        lock.withLock {
            guard case .connecting = state else { return false }
            state = .running
            return true
        }
    }

    /// Stop waiting. `true` means the command already owns a session and needs
    /// a background handle; `false` means it never started.
    public func giveUp() -> Bool {
        lock.withLock {
            switch state {
            case .running: return true
            case .connecting, .abandoned:
                state = .abandoned
                return false
            }
        }
    }
}

/// Thrown by a command that was abandoned before it started, so the connection
/// it was waiting on is kept while the command itself is not.
nonisolated public struct AgentCommandNotStarted: Error {}

/// A one-shot arrival bell whose wait can be abandoned.
///
/// `Task.result` cannot be given up on, which is the whole difficulty: waiting
/// for a command has to be interruptible even though the command is not.
nonisolated public final class AgentCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasArrived = false
    private var waiter: CheckedContinuation<Void, Never>?

    public func signal() {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            hasArrived = true
            defer { waiter = nil }
            return waiter
        }
        resume?.resume()
    }

    public func wait() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let arrived: Bool = lock.withLock {
                    if hasArrived { return true }
                    waiter = continuation
                    return false
                }
                if arrived { continuation.resume() }
            }
        } onCancel: {
            // Releases the waiter without claiming the thing arrived: giving up
            // on a wait is not the same event as the command finishing.
            let resume: CheckedContinuation<Void, Never>? = lock.withLock {
                defer { waiter = nil }
                return waiter
            }
            resume?.resume()
        }
    }
}

nonisolated public enum AgentBackgroundCommandError: LocalizedError, Sendable {
    case unknownHandle

    public var errorDescription: String? {
        switch self {
        case .unknownHandle:
            String(
                localized: """
                    No command is running under that handle. It finished and was already reported, \
                    or it was released after going unasked-about for too long.
                    """
            )
        }
    }
}

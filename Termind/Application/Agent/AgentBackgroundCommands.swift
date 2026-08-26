import Foundation

/// What a command looks like to whoever asked about it.
///
/// One shape for both answers, because a caller that has to branch on which
/// kind of reply it got is a caller that will forget to. `exitCode` is `nil`
/// exactly when the command is still running.
nonisolated struct AgentCommandOutcome: Sendable {
    var handle: UUID
    var standardOut: String
    var standardError: String
    var exitCode: Int32?
    var signal: String?
    var isRunning: Bool { exitCode == nil }
}

/// Commands that outlived the turn that started them.
///
/// A tool returns when it decides to, which for `ssh_exec` means reporting what
/// it has rather than blocking a whole turn on a fifteen-minute deploy. The
/// command keeps running on a session handed over from the pool, its output
/// keeps arriving on the card, and this is where the model comes back for the
/// rest of it.
///
/// Owned by `AppModel` rather than by a run, because the point is to outlive
/// one: a handle taken in one turn is answered in a later one, and a run that
/// ends is not a reason to stop a deploy.
///
/// There is deliberately no "kill". Closing a channel does not stop the process
/// on the far side — see the `defer` in `SSHExecSession.executeOnQueue` — so a
/// tool by that name would promise what it cannot do. What can honestly happen
/// is releasing the connection, and that is `sweepIdle`'s job: a handle nobody
/// asks about again is let go, on the same principle as the connection pool's
/// own idle sweep.
actor AgentBackgroundCommands {
    /// Long enough that a model which meant to come back gets the chance, short
    /// enough that a forgotten `tail -f` does not hold a session open all day.
    static let defaultIdleTimeout = Duration.seconds(600)

    private struct Entry {
        let hostID: UUID
        let command: String
        let stream: AgentCommandOutputStream
        let task: Task<SSHExecResult, any Error>
        let session: any SSHExecSessionProtocol
        var lastAskedAt: ContinuousClock.Instant
        /// How many `ssh_wait` calls are blocked on this right now. A command
        /// somebody is already watching needs no announcement — they will
        /// report the outcome themselves, and hearing it twice is worse than
        /// hearing it once.
        var waiters = 0
        var hasBeenAnnounced = false
    }

    private var entries: [UUID: Entry] = [:]
    private let idleTimeout: Duration
    /// `nil` disables the timer, for tests that drive `sweepIdle` themselves
    /// with a synthetic instant. Same seam, and same reason, as the connection
    /// pool's.
    private let sweepInterval: Duration?
    private var sweeper: Task<Void, Never>?

    init(
        idleTimeout: Duration = AgentBackgroundCommands.defaultIdleTimeout,
        sweepInterval: Duration? = .seconds(60)
    ) {
        self.idleTimeout = idleTimeout
        self.sweepInterval = sweepInterval
    }

    var count: Int { entries.count }

    /// Takes ownership of a command still in flight, and of the session it is
    /// running on.
    func adopt(
        hostID: UUID, command: String, stream: AgentCommandOutputStream,
        task: Task<SSHExecResult, any Error>, session: any SSHExecSessionProtocol,
        now: ContinuousClock.Instant = .now,
        announce: (@Sendable (String) -> Void)? = nil
    ) -> UUID {
        let handle = UUID()
        entries[handle] = Entry(
            hostID: hostID, command: command, stream: stream, task: task,
            session: session, lastAskedAt: now
        )
        startSweeping()
        if let announce {
            // Unstructured, and nothing awaits it: it lives exactly as long as
            // the command does. See `settled` for what happens to a structured
            // watcher of a task that ignores cancellation.
            Task { [weak self] in
                _ = await task.result
                await self?.announceCompletion(handle, announce)
            }
        }
        return handle
    }

    /// Tells whoever asked that a command nobody was watching has finished.
    ///
    /// The alternative is silence. A model that takes a handle and never comes
    /// back never learns the outcome, and the output is swept ten minutes later
    /// having been read by no one — a deploy whose result vanishes because the
    /// agent got distracted is the quietest possible failure.
    private func announceCompletion(
        _ handle: UUID, _ announce: @Sendable (String) -> Void
    ) async {
        guard var entry = entries[handle], entry.waiters == 0, !entry.hasBeenAnnounced
        else { return }
        entry.hasBeenAnnounced = true
        entries[handle] = entry
        guard let result = try? await entry.task.value else { return }
        let captured = entry.stream.captured
        announce(Self.completionNotice(
            handle: handle, command: entry.command, result: result,
            standardOut: captured.standardOut, standardError: captured.standardError
        ))
    }

    static func completionNotice(
        handle: UUID, command: String, result: SSHExecResult,
        standardOut: String, standardError: String
    ) -> String {
        var notice = String(
            localized:
                "The background command `\(command)` has finished with exit code \(result.exitCode). Its handle was \(handle.uuidString)."
        )
        if !standardOut.isEmpty { notice += "\n\nstdout:\n\(standardOut)" }
        if !standardError.isEmpty { notice += "\n\nstderr:\n\(standardError)" }
        return notice
    }

    /// Waits up to `timeout` for the command behind `handle` to finish.
    ///
    /// Returns what it has either way. A wait that expires is not an error and
    /// not a failure of the command — it is the same answer `ssh_exec` gave in
    /// the first place, and the handle stays valid for another ask.
    func wait(
        _ handle: UUID, timeout: Duration,
        reporting: (@Sendable (String, String) -> Void)? = nil,
        now: ContinuousClock.Instant = .now
    ) async throws -> AgentCommandOutcome {
        guard var entry = entries[handle] else { throw AgentBackgroundCommandError.unknownHandle }
        entry.lastAskedAt = now
        entries[handle] = entry
        // The output belongs under whichever call is answering for it, and from
        // here that is this one: the `ssh_exec` that started the command has
        // returned, and its progress gate is shut.
        if let reporting { entry.stream.redirect(to: reporting) }

        // Counted across the wait so a completion that lands mid-wait is
        // reported by this call rather than announced behind its back.
        entries[handle]?.waiters += 1
        let didSettle = await Self.settled(entry.task, within: timeout)
        entries[handle]?.waiters -= 1
        guard didSettle else {
            let captured = entry.stream.captured
            return AgentCommandOutcome(
                handle: handle, standardOut: captured.standardOut,
                standardError: captured.standardError, exitCode: nil
            )
        }

        // Finished, so the handle and its session are done. Released here
        // rather than left for the sweep: a session nobody will read from again
        // is an authenticated connection sitting open on someone's server.
        entries.removeValue(forKey: handle)
        stopSweepingIfEmpty()
        let session = entry.session
        Task { await session.disconnect() }
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
    func sweepIdle(now: ContinuousClock.Instant = .now) async -> Int {
        let expired = entries.filter { now - $0.value.lastAskedAt >= idleTimeout }
        for (handle, entry) in expired {
            entries.removeValue(forKey: handle)
            entry.task.cancel()
            await entry.session.disconnect()
        }
        stopSweepingIfEmpty()
        return entries.count
    }

    func closeAll() async {
        let closing = entries.values
        entries.removeAll()
        stopSweepingIfEmpty()
        for entry in closing {
            entry.task.cancel()
            await entry.session.disconnect()
        }
    }

    /// Runs only while something is held. A timer ticking against an empty
    /// registry is a wakeup a laptop pays for and nobody reads.
    private func startSweeping() {
        guard sweeper == nil, let sweepInterval else { return }
        sweeper = Task { [weak self, sweepInterval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: sweepInterval) } catch { return }
                guard let self, await self.sweepIdle(now: .now) > 0 else { return }
            }
        }
    }

    private func stopSweepingIfEmpty() {
        guard entries.isEmpty else { return }
        sweeper?.cancel()
        sweeper = nil
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
    static func settled<T>(
        _ task: Task<T, any Error>, within timeout: Duration
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
nonisolated final class AgentCommandHandover: @unchecked Sendable {
    private enum State {
        case connecting
        case running(any SSHExecSessionProtocol)
        case abandoned
    }

    private let lock = NSLock()
    private var state = State.connecting

    /// The command is about to start. `false` means the call already gave up
    /// while the connection was still being made, so it must not start at all —
    /// a command nobody holds a handle to would run, print, and finish unseen.
    func beginRunning(on session: any SSHExecSessionProtocol) -> Bool {
        lock.withLock {
            guard case .connecting = state else { return false }
            state = .running(session)
            return true
        }
    }

    /// Stop waiting. The session comes back when the command had already
    /// started and now needs an owner; `nil` when it never started.
    func giveUp() -> (any SSHExecSessionProtocol)? {
        lock.withLock {
            switch state {
            case .running(let session): return session
            case .connecting, .abandoned:
                state = .abandoned
                return nil
            }
        }
    }
}

/// Thrown by a command that was abandoned before it started, so the connection
/// it was waiting on is kept while the command itself is not.
nonisolated struct AgentCommandNotStarted: Error {}

/// A one-shot arrival bell whose wait can be abandoned.
///
/// `Task.result` cannot be given up on, which is the whole difficulty: waiting
/// for a command has to be interruptible even though the command is not.
nonisolated final class AgentCompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var hasArrived = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        let resume: CheckedContinuation<Void, Never>? = lock.withLock {
            hasArrived = true
            defer { waiter = nil }
            return waiter
        }
        resume?.resume()
    }

    func wait() async {
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

nonisolated enum AgentBackgroundCommandError: LocalizedError, Sendable {
    case unknownHandle

    var errorDescription: String? {
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

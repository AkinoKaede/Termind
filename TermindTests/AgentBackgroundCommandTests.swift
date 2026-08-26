import Foundation
import Testing

@testable import Termind

private actor StubSession: SSHExecSessionProtocol {
    private(set) var didDisconnect = false

    func connect(using configuration: SSHConnectionConfiguration) async throws {}

    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        SSHExecResult(
            stdout: "", stderr: "", exitCode: 0, signal: nil,
            stdoutTruncated: false, stderrTruncated: false
        )
    }

    func disconnect() async { didDisconnect = true }
}

private func exited(_ code: Int32, stdout: String = "") -> SSHExecResult {
    SSHExecResult(
        stdout: stdout, stderr: "", exitCode: code, signal: nil,
        stdoutTruncated: false, stderrTruncated: false
    )
}

/// A command that outlives the turn that started it.
@Suite
struct AgentBackgroundCommandTests {

    // MARK: - Racing a deadline

    @Test
    func aCommandThatBeatsItsDeadlineIsReportedSettled() async {
        let task = Task<SSHExecResult, any Error> { exited(0) }
        #expect(await AgentBackgroundCommands.settled(task, within: .seconds(30)))
    }

    /// The property the whole design rests on: the deadline is when this *call*
    /// reports back, not when the command is given up on.
    @Test
    func aCommandThatMissesItsDeadlineKeepsRunning() async {
        let released = AsyncRelease()
        let task = Task<SSHExecResult, any Error> {
            await released.wait()
            return exited(0, stdout: "finished anyway")
        }

        #expect(await AgentBackgroundCommands.settled(task, within: .milliseconds(20)) == false)
        #expect(!task.isCancelled, "losing the race must not cancel the command")

        await released.release()
        #expect(try! await task.value.stdout == "finished anyway")
    }

    // MARK: - Still connecting when the deadline lands

    /// Connecting is inside the deadline, so a host that never answers ends the
    /// turn like anything else. What comes back is not a handle, though: there
    /// is no session and no output, and a handle to nothing is worse than
    /// saying nothing ran.
    @Test
    func givingUpDuringTheConnectHandsOverNothing() {
        let handover = AgentCommandHandover()
        #expect(handover.giveUp() == nil)
    }

    /// The half that keeps a command from being orphaned. If the call gave up
    /// while the connection was still being made, the command must not start
    /// once it completes — it would run, print and finish with nobody holding a
    /// handle to it.
    @Test
    func aCommandAbandonedWhileConnectingIsNotStartedAfterwards() {
        let handover = AgentCommandHandover()
        #expect(handover.giveUp() == nil)
        #expect(handover.beginRunning(on: StubSession()) == false)
    }

    @Test
    func aCommandThatStartedInTimeIsHandedOverWithItsSession() {
        let handover = AgentCommandHandover()
        let session = StubSession()
        #expect(handover.beginRunning(on: session))
        #expect(handover.giveUp() === session)
    }

    // MARK: - The registry

    @Test
    func waitingOnAFinishedCommandReportsItAndReleasesTheHandle() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let session = StubSession()
        let handle = await commands.adopt(
            hostID: UUID(), command: "make", stream: AgentCommandOutputStream { _, _ in },
            task: Task { exited(0, stdout: "built") }, session: session
        )

        let outcome = try await commands.wait(handle, timeout: .seconds(30))

        #expect(!outcome.isRunning)
        #expect(outcome.exitCode == 0)
        #expect(outcome.standardOut == "built")
        // An authenticated connection nobody will read from again has no reason
        // to stay open on someone's server.
        #expect(await commands.count == 0)
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.wait(handle, timeout: .seconds(1))
        }
    }

    @Test
    func waitingOnARunningCommandReturnsWhatItHasAndKeepsTheHandle() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let released = AsyncRelease()
        let stream = AgentCommandOutputStream(interval: .zero) { _, _ in }
        let handle = await commands.adopt(
            hostID: UUID(), command: "deploy", stream: stream,
            task: Task { await released.wait(); return exited(0) }, session: StubSession()
        )
        stream.handler(Data("step 1 of 9\n".utf8), false)

        let outcome = try await commands.wait(handle, timeout: .milliseconds(20))

        #expect(outcome.isRunning)
        #expect(outcome.standardOut == "step 1 of 9\n")
        // An expired wait is not a failure and not the end of the command, so
        // the handle has to still be good for another ask.
        #expect(await commands.count == 1)
        await released.release()
    }

    @Test
    func anUnknownHandleSaysSoRatherThanHanging() async {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.wait(UUID(), timeout: .seconds(1))
        }
    }

    /// Output belongs under whichever call is currently answering for it. The
    /// `ssh_exec` that started this one has returned and stopped listening.
    @Test
    func waitingRedirectsTheCommandsOutputToTheCaller() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let released = AsyncRelease()
        let stream = AgentCommandOutputStream(interval: .zero) { _, _ in }
        let handle = await commands.adopt(
            hostID: UUID(), command: "deploy", stream: stream,
            task: Task { await released.wait(); return exited(0) }, session: StubSession()
        )

        let seen = Sink()
        _ = try await commands.wait(
            handle, timeout: .milliseconds(20), reporting: { out, _ in seen.append(out) }
        )
        stream.handler(Data("step 2\n".utf8), false)

        #expect(seen.values == ["step 2\n"])
        await released.release()
    }

    @Test
    func theSweepReleasesWhatNobodyAskedAboutAndLeavesTheRest() async {
        let commands = AgentBackgroundCommands(idleTimeout: .seconds(600), sweepInterval: nil)
        let forgotten = StubSession()
        let released = AsyncRelease()
        let start = ContinuousClock.now
        let stale = await commands.adopt(
            hostID: UUID(), command: "tail -f", stream: AgentCommandOutputStream { _, _ in },
            task: Task { await released.wait(); return exited(0) }, session: forgotten,
            now: start
        )
        _ = await commands.adopt(
            hostID: UUID(), command: "deploy", stream: AgentCommandOutputStream { _, _ in },
            task: Task { await released.wait(); return exited(0) }, session: StubSession(),
            now: start.advanced(by: .seconds(590))
        )

        let remaining = await commands.sweepIdle(now: start.advanced(by: .seconds(601)))

        #expect(remaining == 1, "only the one past its window is let go")
        #expect(await forgotten.didDisconnect)
        await #expect(throws: AgentBackgroundCommandError.self) {
            try await commands.wait(stale, timeout: .seconds(1))
        }
        await released.release()
    }

    /// The window is a promise, and until this landed nothing kept it: the
    /// sweep existed but nothing ever called it, so a released handle stayed
    /// held until the app quit.
    @Test
    func theTimerReleasesAHandleOnceItsWindowHasPassed() async throws {
        let commands = AgentBackgroundCommands(
            idleTimeout: .zero, sweepInterval: .milliseconds(20)
        )
        let session = StubSession()
        let released = AsyncRelease()
        _ = await commands.adopt(
            hostID: UUID(), command: "tail -f", stream: AgentCommandOutputStream { _, _ in },
            task: Task { await released.wait(); return exited(0) }, session: session
        )

        for _ in 0..<50 where await commands.count > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(await commands.count == 0)
        #expect(await session.didDisconnect)
        await released.release()
    }

    // MARK: - Telling the model when nobody asked

    /// The quietest possible failure this design could have: a model takes a
    /// handle, gets distracted, and the deploy's outcome is swept ten minutes
    /// later having been read by no one.
    @Test
    func aCommandNobodyWaitedOnAnnouncesItself() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let announced = Sink()
        _ = await commands.adopt(
            hostID: UUID(), command: "deploy.sh",
            stream: AgentCommandOutputStream { _, _ in },
            task: Task { exited(0, stdout: "done") }, session: StubSession(),
            announce: { announced.append($0) }
        )

        for _ in 0..<50 where announced.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(announced.values.count == 1)
        #expect(announced.values.first?.contains("deploy.sh") == true)
        #expect(announced.values.first?.contains("exit code 0") == true)
    }

    /// The other half: somebody watching reports it themselves, so announcing
    /// it as well would tell the model the same thing twice.
    @Test
    func aCommandSomebodyIsWaitingOnIsNotAlsoAnnounced() async throws {
        let commands = AgentBackgroundCommands(sweepInterval: nil)
        let announced = Sink()
        let released = AsyncRelease()
        let handle = await commands.adopt(
            hostID: UUID(), command: "deploy.sh",
            stream: AgentCommandOutputStream { _, _ in },
            task: Task { await released.wait(); return exited(0, stdout: "done") },
            session: StubSession(),
            announce: { announced.append($0) }
        )

        async let outcome = commands.wait(handle, timeout: .seconds(30))
        try await Task.sleep(for: .milliseconds(20))
        await released.release()

        #expect(try await outcome.exitCode == 0)
        try await Task.sleep(for: .milliseconds(50))
        #expect(announced.values.isEmpty, "the waiter already reported it")
    }

    // MARK: - Shape

    @Test @MainActor
    func waitIsRegisteredAndReadOnly() {
        let tools = AgentBuiltInTools.make(
            hosts: AgentHostResolver(store: HostStore()),
            connections: AgentConnectionPool(
                configuration: { _ in throw AgentToolError.invalidHost },
                routeFingerprint: { _ in "" },
                openExec: { _ in throw AgentToolError.invalidHost },
                openSFTP: { _ in throw AgentToolError.invalidHost },
                sweepInterval: nil
            )
        )
        let wait = tools.first { $0.descriptor.name == "ssh_wait" }
        #expect(wait != nil)
        // It reads a buffer and a task. Nothing it does reaches the host, so
        // stopping to ask permission for it would be asking about nothing.
        #expect(wait?.descriptor.safety == .locallyReadOnly)
        #expect(wait?.descriptor.concurrency == .parallel)
        // No kill: closing a channel does not stop a remote process, so a tool
        // by that name would promise what it cannot do.
        #expect(!tools.contains { $0.descriptor.name.hasPrefix("ssh_kill") })
    }
}

/// One-shot gate for a task that must not finish until the test says so.
private actor AsyncRelease {
    private var isReleased = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isReleased = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Locked rather than an actor, because the callback under test may not await.
private nonisolated final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

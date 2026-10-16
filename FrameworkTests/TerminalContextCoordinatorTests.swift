import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct TerminalContextCoordinatorTests {
    private func context(_ pane: String = "a", instance: String = "one") -> TerminalShellContext {
        .init(
            identity: .init(backend: "test", server: "server", session: "session", pane: pane, shellInstance: instance),
            shell: "bash", directory: "/\(pane)", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.directory, .commandLifecycle, .readDraft, .replaceDraft])
    }

    @Test(arguments: ["shell", "tmux", "zellij", "zmx", "herdr"])
    func commandsKeepTheReportedDirectoryWithoutKeepingOperationTickets(backend: String) throws {
        let model = TerminalContextCoordinator()
        var shell = TerminalShellContext(
            identity: .init(backend: backend, server: "s", session: "s", pane: "a", shellInstance: "one"),
            shell: "bash", directory: "/before", home: "/home/test", promptReady: true, sequence: 1,
            capabilities: [.directory, .commandLifecycle, .readDraft, .replaceDraft])
        let status: TerminalRuntimeUpdate.Status = backend == "shell" ? .ordinary : .multiplexer
        func receive(_ events: [TerminalContextEvent] = []) {
            model.receive(
                .init(status: status, active: shell.identity, contexts: [shell], events: events),
                generation: model.generation)
        }
        receive()
        let draft = try #require(model.ticket(requiring: .replaceDraft))
        let directory = try #require(model.ticket(requiring: .directory))
        shell.promptReady = false
        shell.capabilities = [.commandLifecycle]
        shell.sequence = 2
        receive([.init(context: shell.identity, sequence: 2, payload: .commandStarted("sleep 10"))])
        #expect(model.directory == "/before")
        #expect(model.ticket(requiring: .readDraft) == nil)
        #expect(model.ticket(requiring: .replaceDraft) == nil)
        #expect(model.ticket(requiring: .directory) == nil)
        #expect(!model.isCurrent(draft, requiring: .replaceDraft))
        #expect(!model.isCurrent(directory, requiring: .directory))
        receive()
        #expect(model.directory == "/before")

        // A chpwd event may arrive before the next prompt (for example, zsh's cd hook).
        shell.directory = "/after"
        shell.sequence = 3
        receive([.init(context: shell.identity, sequence: 3, payload: .directory("/after"))])
        #expect(model.directory == "/after")
        #expect(model.ticket(requiring: .replaceDraft) == nil)
        shell.promptReady = true
        shell.sequence = 5
        shell.capabilities = [.directory, .commandLifecycle, .readDraft, .replaceDraft]
        receive([
            .init(context: shell.identity, sequence: 4, payload: .commandFinished(0, duration: 10)),
            .init(context: shell.identity, sequence: 5, payload: .promptReady),
        ])
        #expect(model.directory == "/after")
        #expect(model.ticket(requiring: .replaceDraft) != nil)
        #expect(!model.isCurrent(draft, requiring: .replaceDraft))

        var replacement = context("b", instance: "new")
        replacement.directory = nil
        model.receive(
            .init(status: status, active: replacement.identity, contexts: [shell, replacement]),
            generation: model.generation)
        #expect(model.directory == nil)
        receive()
        #expect(model.directory == "/after")
        model.receive(.init(status: .multiplexer, contexts: [shell]), generation: model.generation)
        #expect(model.directory == nil)
        receive()
        model.reset()
        #expect(model.directory == nil)
    }

    @Test func activeContextIsNotInferredFromEventSource() {
        let model = TerminalContextCoordinator()
        let a = context()
        let b = context("b")
        let update = TerminalRuntimeUpdate(
            status: .multiplexer, active: a.identity, contexts: [a, b],
            events: [.init(context: b.identity, sequence: 1, payload: .directory("/wrong"))])
        model.receive(update, generation: model.generation)
        #expect(model.directory == "/a")
        #expect(model.active?.identity == a.identity)
    }

    @Test func ticketsExpireOnInputSwitchDisconnectAndCapabilityLoss() throws {
        let model = TerminalContextCoordinator()
        let a = context()
        model.receive(.init(status: .ordinary, active: a.identity, contexts: [a]), generation: model.generation)
        let ticket = try #require(model.ticket(requiring: .readDraft))
        model.noteInput()
        #expect(!model.isCurrent(ticket, requiring: .readDraft))
        let next = try #require(model.ticket(requiring: .readDraft))
        model.receive(.init(status: .unavailable), generation: model.generation)
        #expect(model.directory == nil)
        #expect(!model.isCurrent(next, requiring: .readDraft))
        let old = model.generation
        model.reset()
        model.receive(.init(status: .ordinary, active: a.identity, contexts: [a]), generation: old)
        #expect(model.active == nil)
    }

    @Test func journalReplayDoesNotReannounceOldCommandsAndGapsCannotCompleteThem() {
        let model = TerminalContextCoordinator()
        var a = context()
        a.sequence = 9
        let past = TerminalContextEvent(context: a.identity, sequence: 8, payload: .commandStarted("old"))
        #expect(
            model.receive(
                .init(status: .multiplexer, active: a.identity, contexts: [a], events: [past]),
                generation: model.generation
            ).isEmpty)
        let start = TerminalContextEvent(context: a.identity, sequence: 10, payload: .commandStarted("new"))
        let finish = TerminalContextEvent(
            context: a.identity, sequence: 12, payload: .commandFinished(0, duration: 1))
        a.sequence = 12
        let accepted = model.receive(
            .init(status: .multiplexer, active: a.identity, contexts: [a], events: [start, finish]),
            generation: model.generation)
        #expect(accepted == [start])
        #expect(
            model.receive(
                .init(status: .multiplexer, active: a.identity, contexts: [a], events: [start, finish]),
                generation: model.generation
            ).isEmpty)
    }

    @Test func independentPanesCompleteWithoutOverwritingEachOther() {
        let model = TerminalContextCoordinator()
        let monitor = TerminalCommandMonitor()
        monitor.beginConnection()
        let a = context()
        let b = context("b")
        model.receive(.init(status: .multiplexer, active: a.identity, contexts: [a, b]), generation: model.generation)
        var nextA = a
        var nextB = b
        nextA.sequence = 3
        nextB.sequence = 3
        let events: [TerminalContextEvent] = [
            .init(context: a.identity, sequence: 2, payload: .commandStarted("first")),
            .init(context: b.identity, sequence: 2, payload: .commandStarted("second")),
            .init(context: a.identity, sequence: 3, payload: .commandFinished(0, duration: 10)),
            .init(context: b.identity, sequence: 3, payload: .commandFinished(1, duration: 20)),
        ]
        monitor.receiveRuntimeEvents(
            model.receive(
                .init(status: .multiplexer, active: a.identity, contexts: [nextA, nextB], events: events),
                generation: model.generation))
        #expect(monitor.unreadCompletionCount == 2)
        monitor.receiveOSC133(exitCode: 0, durationNanos: 20_000_000_000)
        #expect(monitor.unreadCompletionCount == 2)
    }

    @Test func anUnconfirmedForegroundDoesNotForgetTheOuterShellCommand() {
        let model = TerminalContextCoordinator()
        var shell = context()
        shell = .init(
            identity: .init(backend: "shell", server: "c", session: "c", pane: "shell", shellInstance: "s"),
            shell: shell.shell, directory: shell.directory, home: shell.home, promptReady: false,
            sequence: 1, capabilities: [.commandLifecycle])
        model.receive(
            .init(
                status: .unknown, contexts: [shell],
                events: [.init(context: shell.identity, sequence: 1, payload: .commandStarted("sleep 2"))]),
            generation: model.generation)
        model.receive(.init(status: .unknown), generation: model.generation)
        let event = TerminalContextEvent(
            context: shell.identity, sequence: 2, payload: .commandFinished(0, duration: 2))
        shell.sequence = 2
        #expect(
            model.receive(
                .init(status: .unknown, contexts: [shell], events: [event]), generation: model.generation) == [event])
    }

    @Test func aRuntimeAdapterDoesNotNeedATmuxDataModel() async throws {
        struct Adapter: TerminalRuntimeAdapter {
            let update: TerminalRuntimeUpdate
            func inspect(terminal: String) async throws -> TerminalRuntimeUpdate { update }
        }
        let model = TerminalContextCoordinator()
        let context = context("different-backend")
        try await model.refresh(
            using: Adapter(update: .init(status: .multiplexer, active: context.identity, contexts: [context])),
            terminal: "opaque-terminal-binding")
        #expect(model.directory == "/different-backend")
        #expect(model.ticket(requiring: .replaceDraft) != nil)
        var old = context
        old.sequence = 0
        old.directory = "/stale"
        model.receive(.init(status: .multiplexer, active: old.identity, contexts: [old]), generation: model.generation)
        #expect(model.directory == "/different-backend")
    }

    @Test func aCommandBetweenPollsInvalidatesDraftsEvenWhenThePromptLooksUnchanged() throws {
        let model = TerminalContextCoordinator()
        var shell = context()
        model.receive(
            .init(status: .multiplexer, active: shell.identity, contexts: [shell]), generation: model.generation)
        let draft = try #require(model.ticket(requiring: .replaceDraft))
        shell.sequence = 2
        model.receive(
            .init(
                status: .multiplexer, active: shell.identity, contexts: [shell],
                events: [
                    .init(context: shell.identity, sequence: 2, payload: .draft(request: "request", value: "text"))
                ]),
            generation: model.generation)
        #expect(model.isCurrent(draft, requiring: .replaceDraft))
        shell.sequence = 5
        model.receive(
            .init(
                status: .multiplexer, active: shell.identity, contexts: [shell],
                events: [
                    .init(context: shell.identity, sequence: 3, payload: .commandStarted("true")),
                    .init(context: shell.identity, sequence: 4, payload: .commandFinished(0, duration: 0)),
                    .init(context: shell.identity, sequence: 5, payload: .promptReady),
                ]),
            generation: model.generation)
        #expect(!model.isCurrent(draft, requiring: .replaceDraft))
        #expect(model.directory == shell.directory)
    }
}

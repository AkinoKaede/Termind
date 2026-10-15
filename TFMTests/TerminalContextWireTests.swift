import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct TerminalContextWireTests {
    private let token = "4EA6E90A-81DA-4879-ACAF-D91CA84BD817"

    @Test func managedNamesAreCompactAndNeverGrantOwnershipByName() throws {
        let owner = try #require(UUID(uuidString: token))
        let name = RemoteTmuxCommands.managedSessionName(token: owner)
        #expect(name.hasPrefix("termind-"))
        #expect(name.utf8.count == 24)
        #expect(!name.contains(owner.uuidString))
        #expect(RemoteTmuxCommands.managedSessionName(token: owner) == name)
        #expect(RemoteTmuxCommands.managedSessionName(token: UUID()) != name)
        let command = try RemoteTmuxCommands.create(token: owner, startupCommand: nil, shellIntegration: false)
        #expect(command.contains("-s '\(name)'"))
        #expect(command.contains("TERMIND_TMUX_OWNER=\(owner.uuidString)' ] || exit 79"))
    }

    private func record(pane: String = "%1", sequence: Int = 2) -> String {
        """
        M1|\(token)|\(pane)|ctx.ABCDEF|bash|%2Fhome%2Ftest|123
        R1|\(sequence)|1|%2Ftmp%2Fa%7Cb
        E1|1|directory|%2Ftmp%2Fa%7Cb|
        E1|2|prompt||

        """
    }

    @Test func recordDecodesNamesAsDataAndRejectsBrokenSequences() throws {
        let parsed = try RemoteShellContextRecord(record())
        #expect(parsed.directory == "/tmp/a|b")
        #expect(try RemoteShellContextRecord(record().replacingOccurrences(of: "\n", with: "\r\n")).ready)
        #expect(throws: (any Error).self) { try RemoteShellContextRecord(record(sequence: 1)) }
        #expect(throws: (any Error).self) { try RemoteShellContextRecord(record(pane: "%1;touch /tmp/x")) }
    }

    @Test func activePaneIsBoundToTheClientAndUninstrumentedPanesHaveNoDraftCapability() throws {
        let prefix = """
            tmux 3.3a
            C|/dev/pts/1|555|100|777|$0|99|%2||root
            P|%1|123|0|0|bash
            P|%2|456|0|0|unknown
            BEGIN
            """
        let text = prefix + "\n" + record() + "END\nDONE\n"
        let update = try RemoteTmuxRuntimeAdapter.parse(text, terminal: "/dev/pts/1")
        #expect(update.active?.pane == "%2")
        #expect(update.contexts.first { $0.identity == update.active }?.capabilities.isEmpty == true)
        #expect(throws: (any Error).self) {
            try RemoteTmuxRuntimeAdapter.parse(text, terminal: "/dev/pts/other")
        }
        let independent = text.replacingOccurrences(of: "|%2||root", with: "|%2|active-pane|root")
        #expect(try RemoteTmuxRuntimeAdapter.parse(independent, terminal: "/dev/pts/1").status == .unavailable)
    }

    @Test func connectionScopedFramesSurviveEverySplitWithoutLeakingControlText() throws {
        let frame = Data("\u{1B}]777;TermindContext=\(token);\(record(pane: "shell"))\u{7}".utf8)
        for split in 0...frame.count {
            var filter = RemoteTerminalContextFilter(token: token)
            let first = filter.receive(Data(frame.prefix(split)))
            let second = filter.receive(Data(frame.dropFirst(split)))
            #expect(first.output.isEmpty && second.output.isEmpty)
            let updates = first.contexts + second.contexts
            #expect(updates.count == 1)
            #expect(updates.first?.active?.pane == "shell")
        }
    }

    @Test func runtimeBudgetNeverQueuesBehindATerminal() async throws {
        let budget = SSHChannelBudget(maximum: 1)
        let terminal = try await budget.acquire()
        #expect(budget.tryAcquire() == nil)
        terminal.release()
        let observation = try #require(budget.tryAcquire())
        observation.release()
        budget.close()
        #expect(budget.tryAcquire() == nil)
    }

    @Test func malformedAndOversizedFramesCannotEnableCapabilities() throws {
        var filter = RemoteTerminalContextFilter(token: token)
        let bad = record(pane: "shell").replacingOccurrences(of: "%2Ftmp", with: "%GGtmp")
        let update = filter.receive(Data("\u{1B}]777;TermindContext=\(token);\(bad)\u{7}".utf8))
        #expect(update.contexts.map(\.status) == [.unavailable])
        #expect(update.output.isEmpty)
        let oversized = Data(
            ("\u{1B}]777;TermindContext=\(token);" + String(repeating: "x", count: 70_000) + "\u{7}visible").utf8)
        let large = filter.receive(oversized)
        #expect(large.contexts.map(\.status) == [.unavailable])
        #expect(String(decoding: large.output, as: UTF8.self) == "visible")
    }

    @Test func shellRestartAndUnsafeModesCannotReuseTheOldPrompt() throws {
        let base = """
            tmux 3.3a
            C|/dev/pts/1|555|100|777|$0|99|%1||root
            P|%1|123|0|0|bash
            BEGIN
            """
        let text = base + "\n" + record() + "END\nDONE\n"
        for unsafe in [
            text.replacingOccurrences(of: "P|%1|123|0|0|bash", with: "P|%1|123|1|0|bash"),
            text.replacingOccurrences(of: "P|%1|123|0|0|bash", with: "P|%1|123|0|1|bash"),
            text.replacingOccurrences(of: "P|%1|123|0|0|bash", with: "P|%1|456|0|0|bash"),
            text.replacingOccurrences(of: "P|%1|123|0|0|bash", with: "P|%1|123|0|0|unknown"),
        ] {
            let update = try RemoteTmuxRuntimeAdapter.parse(unsafe, terminal: "/dev/pts/1")
            let active = try #require(update.contexts.first { $0.identity == update.active })
            #expect(!active.capabilities.contains(.directory))
            #expect(!active.capabilities.contains(.replaceDraft))
        }
    }

    @Test @MainActor
    func prefixModePreservesDirectoryButInvalidatesDraftOperations() throws {
        let header = """
            tmux 3.3a
            C|/dev/pts/1|555|100|777|$0|99|%1||root
            P|%1|123|0|0|bash
            BEGIN
            """
        let text = header + "\n" + record() + "END\nDONE\n"
        let coordinator = TerminalContextCoordinator()
        let ordinary = try RemoteTmuxRuntimeAdapter.parse(text, terminal: "/dev/pts/1")
        coordinator.receive(ordinary, generation: coordinator.generation)
        let draft = try #require(coordinator.ticket(requiring: .replaceDraft))
        let identity = coordinator.active?.identity
        let prefix = try RemoteTmuxRuntimeAdapter.parse(
            text.replacingOccurrences(of: "|%1||root", with: "|%1||prefix"), terminal: "/dev/pts/1")

        coordinator.receive(prefix, generation: coordinator.generation)

        #expect(coordinator.active?.identity == identity)
        #expect(coordinator.directory == "/tmp/a|b")
        #expect(coordinator.ticket(requiring: .directory) != nil)
        #expect(coordinator.ticket(requiring: .readDraft) == nil)
        #expect(coordinator.ticket(requiring: .replaceDraft) == nil)
        #expect(!coordinator.isCurrent(draft, requiring: .replaceDraft))

        coordinator.receive(ordinary, generation: coordinator.generation)
        #expect(coordinator.directory == "/tmp/a|b")
        #expect(coordinator.ticket(requiring: [.readDraft, .replaceDraft]) != nil)
        #expect(!coordinator.isCurrent(draft, requiring: .replaceDraft))
    }
}

import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct WorkingDirectoryTests {
    @Test
    func ghosttyWorkingDirectoryUpdatesSSHSession() async {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "Host")

        #expect(sshSession.workingDirectory == nil)
        sshSession.terminalState.terminalDidChangeWorkingDirectory("")
        await Task.yield()
        #expect(sshSession.workingDirectory == nil)

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/var/log")
        await Task.yield()

        #expect(sshSession.workingDirectory == "/var/log")
    }

    @Test
    func unknownDirectoryIsNotAttachedToContext() {
        let host = Host(name: "Host", host: "host.example")
        let store = HostStore(hosts: [host])
        let workspace = Workspace.sshSession(host: host)

        workspace.refreshConversationContext(in: store)

        #expect(workspace.workingDirectory == nil)
        #expect(workspace.conversation.contextChips.map(\.kind) == [.host])
    }

    @Test
    func sftpSessionPathIsAttachedToAIContext() {
        let host = Host(name: "Files", host: "files.example")
        let store = HostStore(hosts: [host])
        let workspace = Workspace.sftpSession(host: host)

        workspace.refreshConversationContext(in: store)

        #expect(workspace.workingDirectory == "/")
        #expect(workspace.conversation.contextChips.map(\.kind) == [.host, .directory])
        #expect(workspace.conversation.contextChips.map(\.label) == ["Files", "/"])
    }

    @Test
    func directoryChangesReplacePinnedChipAndPreserveOtherContext() async {
        let host = Host(name: "Host", host: "host.example")
        let store = HostStore(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        workspace.refreshConversationContext(in: store)
        workspace.conversation.addChip(
            ContextChip(kind: .output, label: "Last 200 lines", approximateTokens: 1_450)
        )

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/var/log")
        await Task.yield()
        sshSession.terminalState.terminalDidChangeWorkingDirectory("/srv/app")
        await Task.yield()

        let chips = workspace.conversation.contextChips
        #expect(chips.map(\.kind) == [.host, .directory, .output])
        #expect(chips.map(\.label) == ["Host", "/srv/app", "Last 200 lines"])
    }

    @Test
    func backgroundPaneDoesNotReplaceFocusedDirectoryContext() async {
        let firstHost = Host(name: "First", host: "first.example")
        let secondHost = Host(name: "Second", host: "second.example")
        let store = HostStore(hosts: [firstHost, secondHost])
        let workspace = Workspace.sshSession(host: firstHost)
        let firstPane = workspace.focusedPane
        workspace.splitFocusedPane(axis: .horizontal, with: .sshSession(host: secondHost))
        let secondSSHSession = workspace.focusedPane.sshSession!
        let firstSSHSession = firstPane.sshSession!
        workspace.refreshConversationContext(in: store)

        firstSSHSession.terminalState.terminalDidChangeWorkingDirectory("/first")
        await Task.yield()
        #expect(
            !workspace.conversation.contextChips.contains { $0.kind == .directory }
        )

        secondSSHSession.terminalState.terminalDidChangeWorkingDirectory("/second")
        await Task.yield()
        #expect(
            workspace.conversation.contextChips.first { $0.kind == .directory }?.label
                == "/second"
        )

        workspace.focus(firstPane.id)
        workspace.refreshConversationContext(in: store)
        #expect(
            workspace.conversation.contextChips.first { $0.kind == .directory }?.label
                == "/first"
        )
    }

    @Test
    func disconnectAndReconnectClearStaleDirectory() async {
        let host = Host(name: "Host", host: "host.example")
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        workspace.refreshConversationContext(in: HostStore(hosts: [host]))
        sshSession.terminalState.terminalDidChangeWorkingDirectory("/stale")
        await Task.yield()
        #expect(sshSession.workingDirectory == "/stale")
        #expect(
            workspace.conversation.contextChips.contains { $0.kind == .directory }
        )

        sshSession.disconnect()
        #expect(sshSession.workingDirectory == nil)
        #expect(
            !workspace.conversation.contextChips.contains { $0.kind == .directory }
        )

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/stale-again")
        await Task.yield()
        sshSession.connect(using: HostStore())
        #expect(sshSession.workingDirectory == nil)
        #expect(
            !workspace.conversation.contextChips.contains { $0.kind == .directory }
        )
    }
}

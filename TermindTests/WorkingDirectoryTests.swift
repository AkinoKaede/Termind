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
    func disconnectAndReconnectClearStaleDirectory() async {
        let host = Host(name: "Host", host: "host.example")
        let workspace = Workspace.sshSession(host: host)
        let sshSession = workspace.focusedPane.sshSession!
        sshSession.terminalState.terminalDidChangeWorkingDirectory("/stale")
        await Task.yield()
        #expect(sshSession.workingDirectory == "/stale")

        sshSession.disconnect()
        #expect(sshSession.workingDirectory == nil)

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/stale-again")
        await Task.yield()
        sshSession.connect(using: HostStore())
        #expect(sshSession.workingDirectory == nil)
    }
}

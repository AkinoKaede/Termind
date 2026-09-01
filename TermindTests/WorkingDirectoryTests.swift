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
    func shellIntegrationHomeControlsOnlyDisplayedDirectory() async {
        let sshSession = SSHSessionModel(hostID: UUID(), title: "Host")
        sshSession.terminalState.terminalDidChangeWorkingDirectory("/home/deploy/project")
        await Task.yield()

        #expect(sshSession.displayedWorkingDirectory == nil)
        sshSession.receiveShellIntegrationEvent(
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/deploy")
        )

        #expect(sshSession.displayedWorkingDirectory == "~/project")
        #expect(sshSession.workingDirectory == "/home/deploy/project")
    }

    @Test
    func workspaceSubtitleTracksSSHDirectoryEvenWhenRenamed() async throws {
        let host = Host(name: "Host", host: "host.example")
        let store = HostLibraryModel(hosts: [host])
        let workspace = Workspace.sshSession(host: host)
        let window = WindowModel(workspaces: [workspace])
        let sshSession = try #require(workspace.focusedPane.sshSession)
        sshSession.status = .connected
        sshSession.receiveShellIntegrationEvent(
            .available(shell: "zsh", systemInfo: nil, homeDirectory: "/home/deploy")
        )
        sshSession.terminalState.terminalDidChangeWorkingDirectory("/home/deploy/project")
        await Task.yield()

        #expect(workspace.subtitle(in: store) == "~/project")
        window.rename(workspace.id, to: "Production")
        #expect(workspace.title(in: store) == "Production")
        #expect(workspace.subtitle(in: store) == "~/project")

        sshSession.terminalState.terminalDidChangeWorkingDirectory("/var/log")
        await Task.yield()
        #expect(workspace.subtitle(in: store) == "/var/log")

        sshSession.status = .disconnected
        #expect(workspace.subtitle(in: store) == nil)
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
        sshSession.connect(using: HostLibraryModel())
        #expect(sshSession.workingDirectory == nil)
    }
}

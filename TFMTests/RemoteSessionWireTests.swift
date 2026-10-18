import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

/// Opt-in: Scripts/ssh-tmux-session-fixture.py runs isolated OpenSSH with MaxSessions=1 and tmux >= 3.3.
/// The JSON fixture holds only paths and a pinned test-server fingerprint.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"] != nil), .serialized)
@MainActor
struct RemoteSessionWireTests {
    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
        let privateKeyPath: String
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationMultiClientDetachRestoreAndOwnedTermination() async throws {
        let fixture = try loadFixture()
        let hostID = UUID()
        let coordinator = RemoteSessionCoordinator()
        let selectionMonitor = Task {
            while !Task.isCancelled {
                if let prompt = coordinator.prompt {
                    switch prompt.failure {
                    case .commandFailed(let message):
                        let redacted = message.replacingOccurrences(
                            of: #"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}"#,
                            with: "<redacted>", options: .regularExpression)
                        Issue.record("Unexpected remote command failure during create/restore: \(redacted)")
                    case .invalidResponse:
                        Issue.record("Unexpected remote response during create/restore")
                    case .ownershipMismatch:
                        Issue.record("Unexpected ownership mismatch during create/restore")
                    default:
                        Issue.record("Unexpected session selection during automatic create/restore")
                    }
                    coordinator.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        defer { selectionMonitor.cancel() }
        let marker = "/tmp/termind-once-\(UUID().uuidString)"
        let channel = SSHPTYChannel(
            output: { _ in }, exit: { _ in }, maxSessionsPolicy: .init(preferences: .init(maxSessions: 1)))
        await channel.configureStartup { execute in
            try await coordinator.prepare(
                preferences: .init(enabled: true, onConnect: .createManaged), registry: .live,
                execute: execute, hostID: hostID, endpoint: "localhost:\(fixture.port)", username: "root",
                startupCommand: "printf once >> '\(marker)'", requiresNewSession: true, shellIntegration: false)
        }
        try await connect(channel, fixture: fixture, hostID: hostID)
        let reference = try #require(coordinator.attachment)
        #expect(reference.isManaged)
        let owner = try #require(reference.ownershipToken)
        #expect(!reference.session.name.lowercased().contains(owner.uuidString.lowercased()))
        await channel.resize(columns: 103, rows: 37, widthPixels: 0, heightPixels: 0)
        try await Task.sleep(for: .milliseconds(250))

        let second = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await second.configureStartup { execute in
            let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
            let before = try await backend.sessions()
            #expect(before.contains { backend.matches(reference, session: $0) && $0.clients == 1 })
            let target = try RemoteTmuxCommands.quote(reference.session.id)
            let size = try await execute("tmux list-clients -t \(target) -F '#{client_width} #{client_height}'")
            #expect(size.stdout == "103 37\n")
            let innerSize = try await execute(
                "tmux display-message -p -t \(target) '#{window_width} #{window_height} #{pane_width} #{pane_height}'")
            #expect(innerSize.stdout == "103 36 103 36\n")
            return SSHPTYStartupPlan(command: try backend.launch(reference, created: false).command)
        }
        try await connect(second, fixture: fixture, hostID: hostID)
        let observer = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await observer.configureStartup { execute in
            let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
            let sessions = try await backend.sessions()
            #expect(sessions.contains { backend.matches(reference, session: $0) && $0.clients == 2 })
            return nil
        }
        try await connect(observer, fixture: fixture, hostID: hostID)
        await observer.disconnect()
        // Release the first terminal before executing control commands on its MaxSessions=1 transport.
        try await channel.releaseTerminalForControl()
        let execute = try await channel.sessionCommandExecutor()
        let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
        let listed = try await backend.sessions()
        #expect(listed.contains { backend.matches(reference, session: $0) && $0.clients == 1 })
        #expect(try await execute("cat '\(marker)'").stdout == "once")
        await second.disconnect()
        #expect(try await backend.sessions().contains { backend.matches(reference, session: $0) })

        let third = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await third.configureStartup { execute in
            try await coordinator.prepare(
                preferences: .init(enabled: true, onConnect: .createManaged), registry: .live,
                execute: execute, hostID: hostID, endpoint: "localhost:\(fixture.port)", username: "root",
                startupCommand: "printf REPLAY >> '\(marker)'", requiresNewSession: false, shellIntegration: false)
        }
        try await connect(third, fixture: fixture, hostID: hostID)
        #expect(try await execute("cat '\(marker)'").stdout == "once")
        let external = RemoteSessionReference(
            backend: reference.backend, session: reference.session,
            hostID: reference.hostID, endpoint: reference.endpoint, username: reference.username, ownershipToken: nil)
        do {
            try await backend.terminate(external)
            Issue.record("External attachment cannot terminate")
        } catch RemoteSessionFailure.ownershipMismatch {}
        try await backend.terminate(reference)
        #expect(try await backend.sessions().allSatisfy { !backend.matches(reference, session: $0) })
        _ = try await execute("rm -f '\(marker)'")
        await third.disconnect()
        await channel.disconnect()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["bash", "zsh", "fish"])
    func managedShellLoadsUserConfigurationAndDoesNotReplayStartup(shell: String) async throws {
        let fixture = try loadFixture()
        let hostID = UUID()
        let directory = "/tmp/termind-shell-test-\(UUID().uuidString)"
        let channel = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await channel.configureStartup { execute in
            let quotedDirectory = try RemoteTmuxCommands.quote(directory)
            let config = shell == "fish" ? "set -gx TEST_SESSION_CONFIG loaded" : "export TEST_SESSION_CONFIG=loaded"
            let contents = try RemoteTmuxCommands.quote(
                config + "\nprintf 'config\\n' >> '\(directory)/config-count'\n")
            let setup = try await execute(
                """
                umask 077
                mkdir -p \(quotedDirectory)/.config/fish
                printf '%s\\n' \(contents) > \(quotedDirectory)/.bash_profile
                printf '%s\\n' \(contents) > \(quotedDirectory)/.zshrc
                printf '%s\\n' \(contents) > \(quotedDirectory)/.config/fish/config.fish
                """)
            #expect(setup.exitCode == 0)
            let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
            let token = UUID()
            let session = try await backend.create(
                token: token,
                startupCommand:
                    "cd /tmp; printf '%s' \"$TEST_SESSION_CONFIG\" > '\(directory)/config-value'; printf once >> '\(directory)/once'",
                shellIntegration: true,
                environment: [
                    .init(variable: "SHELL", value: "/bin/\(shell)"),
                    .init(variable: "HOME", value: directory),
                    .init(variable: "XDG_CONFIG_HOME", value: "\(directory)/.config"),
                ])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: hostID, endpoint: "localhost:\(fixture.port)",
                username: "root", ownershipToken: token)
            let target = try RemoteTmuxCommands.quote(session.id)
            var initialized = false
            for _ in 0..<100 {
                if try await execute("test -f \(quotedDirectory)/once").exitCode == 0 {
                    initialized = true
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(initialized)
            let configuredValue = try await execute("cat \(quotedDirectory)/config-value").stdout
            #expect(configuredValue == "loaded")
            let actualShell = try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout
            #expect(actualShell == "\(shell)\n")
            #expect(try await execute("tmux display-message -p -t \(target) '#{pane_current_path}'").stdout == "/tmp\n")
            #expect(try await execute("tmux new-window -t \(target)").exitCode == 0)
            var configCount = ""
            for _ in 0..<100 {
                configCount = try await execute("cat \(quotedDirectory)/config-count").stdout
                if configCount == "config\nconfig\n" { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(configCount == "config\nconfig\n")
            let shellPassthrough = try await execute("tmux show-option -A -w -v -t \(target) allow-passthrough")
            #expect(shellPassthrough.stdout == "off\n")
            let journals = try await execute(
                """
                helper=$(tmux show-environment -t \(target) TERMIND_TMUX_HELPERS)
                helper=${helper#TERMIND_TMUX_HELPERS=}
                for file in "$helper"/ctx.*/journal; do head -n 2 "$file"; done
                """)
            #expect(journals.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("M1|") }.count == 2)
            #expect(journals.stdout.contains("|\(shell)|"))
            let programWindow = try await execute("tmux new-window -P -F '#{window_id}' -t \(target) 'sleep 120'")
            #expect(programWindow.exitCode == 0)
            let programTarget = try RemoteTmuxCommands.quote(
                programWindow.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            let passthrough = try await execute("tmux show-option -A -w -v -t \(programTarget) allow-passthrough")
            #expect(passthrough.stdout == "off\n")
            #expect(try await execute("cat \(quotedDirectory)/once").stdout == "once")
            try await backend.terminate(reference)
            #expect(try await backend.sessions().allSatisfy { !backend.matches(reference, session: $0) })
            _ = try await execute("rm -rf \(quotedDirectory)")
            return nil
        }
        try await connect(channel, fixture: fixture, hostID: hostID)
        await channel.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func abruptTransportLossPreservesTheSessionAndDoesNotReplayStartup() async throws {
        let fixture = try loadFixture()
        let hostID = UUID()
        let coordinator = RemoteSessionCoordinator()
        let state = ConnectionState()
        let marker = "/tmp/termind-network-test-\(UUID().uuidString)"
        let channel = SSHPTYChannel(
            output: { _ in },
            exit: { result in
                Task { @MainActor in state.exit = result }
            })
        await channel.configureStartup { execute in
            let parent = try await execute("printf '%s' \"$PPID\"").stdout
            await MainActor.run { state.serverPID = UInt64(parent) }
            return try await coordinator.prepare(
                preferences: .init(enabled: true, onConnect: .createManaged), registry: .live,
                execute: execute, hostID: hostID, endpoint: "localhost:\(fixture.port)", username: "root",
                startupCommand: "printf once >> '\(marker)'", requiresNewSession: false, shellIntegration: false)
        }
        try await connect(channel, fixture: fixture, hostID: hostID)
        let reference = try #require(coordinator.attachment)
        let serverPID = try #require(state.serverPID)
        let control = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await control.configureStartup { _ in nil }
        try await connect(control, fixture: fixture, hostID: hostID)
        try await control.releaseTerminalForControl()
        let execute = try await control.sessionCommandExecutor()
        // Kill only this fixture connection's sshd process, not the tmux server or listener.
        let process = try await execute("ps -o comm= -p \(serverPID)").stdout
        try #require(process.contains("sshd"))
        #expect(try await execute("kill -KILL \(serverPID)").exitCode == 0)
        for _ in 0..<200 {
            if state.exit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failure = state.exit else {
            Issue.record("Abrupt transport loss must report a connection failure, not a detach")
            await channel.disconnect()
            await control.disconnect()
            return
        }
        let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
        #expect(try await backend.sessions().contains { backend.matches(reference, session: $0) })
        try await connect(channel, fixture: fixture, hostID: hostID)
        #expect(coordinator.attachment?.hasSameIdentity(as: reference) == true)
        #expect(try await execute("cat '\(marker)'").stdout == "once")
        try await backend.terminate(reference)
        _ = try await execute("rm -f '\(marker)'")
        await channel.disconnect()
        await control.disconnect()
    }

    @Test(.timeLimit(.minutes(1)))
    func reattachmentLeavesVimAndRunningProcessesUntouched() async throws {
        let fixture = try loadFixture()
        let hostID = UUID()
        let coordinator = RemoteSessionCoordinator()
        let control = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await control.configureStartup { execute in
            let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
            let token = UUID()
            let session = try await backend.create(
                token: token, startupCommand: nil, shellIntegration: true, environment: [])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: hostID, endpoint: "localhost:\(fixture.port)",
                username: "root", ownershipToken: token)
            await MainActor.run { coordinator.attachment = reference }
            return try SSHPTYStartupPlan(command: backend.launch(reference, created: true).command)
        }
        try await connect(control, fixture: fixture, hostID: hostID)
        let reference = try #require(coordinator.attachment)
        try await control.releaseTerminalForControl()
        let execute = try await control.sessionCommandExecutor()
        let target = try RemoteTmuxCommands.quote(reference.session.id)
        _ = try await execute("tmux send-keys -t \(target) 'vim -n -u NONE -i NONE' Enter")
        var running = ""
        for _ in 0..<100 {
            running = try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout
            if running.contains("vim") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(running.contains("vim"))
        let vimBefore = try await execute("tmux capture-pane -p -t \(target)").stdout
        let client = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await client.configureStartup { execute in
            try await coordinator.prepare(
                preferences: .init(enabled: true, onConnect: .createManaged), registry: .live, execute: execute,
                hostID: hostID, endpoint: "localhost:\(fixture.port)", username: "root",
                startupCommand: "echo MUST_NOT_REPLAY", requiresNewSession: false, shellIntegration: true)
        }
        try await connect(client, fixture: fixture, hostID: hostID)
        let vimAfter = try await execute("tmux capture-pane -p -t \(target)").stdout
        #expect(vimAfter == vimBefore)
        await client.write(Data([0x02, 0x64]))
        let backend = try RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute)
        var detached = false
        for _ in 0..<100 {
            detached = try await backend.sessions().contains { $0.id == reference.session.id && $0.clients == 0 }
            if detached { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(detached)
        try await connect(client, fixture: fixture, hostID: hostID)
        let vimReattached = try await execute("tmux capture-pane -p -t \(target)").stdout
        #expect(vimReattached == vimBefore)
        _ = try await execute("tmux send-keys -t \(target) Escape ':q!' Enter")
        for _ in 0..<100 {
            running = try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout
            if !running.contains("vim") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await execute("tmux send-keys -t \(target) 'sleep 120' Enter")
        for _ in 0..<100 {
            running = try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout
            if running == "sleep\n" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(running == "sleep\n")
        let panePID = try await execute("tmux display-message -p -t \(target) '#{pane_pid}'").stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try #require(UInt64(panePID))
        let child = try await execute("pgrep -P \(pid) -x sleep").stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let jobPID = try #require(UInt64(child))
        await client.disconnect()
        try await connect(client, fixture: fixture, hostID: hostID)
        running = try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout
        #expect(running == "sleep\n")
        try await backend.terminate(reference)
        var alive = true
        for _ in 0..<100 {
            let states = try await execute("ps -o stat= -p \(pid),\(jobPID)").stdout
            // A minimal container's PID 1 may retain zombies. Neither the shell nor
            // its foreground job may remain executable after owned termination.
            alive = states.split(whereSeparator: \.isWhitespace).contains { !$0.hasPrefix("Z") && !$0.hasPrefix("X") }
            if !alive { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!alive)
        await client.disconnect()
        await control.disconnect()
    }

    private func loadFixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private final class ConnectionState {
        var serverPID: UInt64?
        var exit: Result<Int32, TermindSSHError>?
    }

    private func connect(_ channel: SSHPTYChannel, fixture: Fixture, hostID: UUID) async throws {
        let key = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
        try await channel.connect(
            using: SSHConnectionRequest(
                configuration: .init(
                    hostID: hostID, host: "127.0.0.1", port: fixture.port, username: "root",
                    credentials: [.privateKey(privateKey: SSHSecret(key), publicKey: nil, passphrase: nil)],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: fixture.hostFingerprint)])),
            shellIntegrationEnabled: false, columns: 80, rows: 24)
    }
}

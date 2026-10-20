// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"] != nil), .serialized)
@MainActor
struct TerminalActivationWireTests {
    @Test(.timeLimit(.minutes(2)))
    func activationRestoresWindowAndPaneWithoutResizingTheClientOrTyping() async throws {
        let fixture = try await TmuxActivationFixture.make()
        do {
            Attachment.record(Data(try await fixture.command("tmux -V").utf8), named: "tmux-version.txt")
            let first = try await fixture.attach(columns: 120, rows: 40)
            let identity = try first.identity()
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 120, rows: 40)
            let second = try await fixture.attach(columns: 40, rows: 22, integrated: false)
            try await fixture.expectSize(columns: 40, rows: 22)
            // A runtime poll or duplicate focus publication must not steal size from another client.
            await first.channel.setTerminalActive(true)
            try await Task.sleep(for: .seconds(1))
            try await fixture.expectSize(columns: 40, rows: 22)
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 120, rows: 40)
            #expect(try await fixture.clientSize(identity.terminal) == "120 40")
            #expect(
                try await fixture.command("tmux list-clients -t \(fixture.target) -F '#{client_pid}'")
                    .split(separator: "\n").count == 2)

            // The final engine viewport must win even if activation overlaps queued window changes.
            await first.channel.setTerminalActive(false)
            await first.channel.resize(columns: 130, rows: 42, widthPixels: 0, heightPixels: 0)
            await first.channel.setTerminalActive(true)
            await first.channel.resize(columns: 140, rows: 45, widthPixels: 0, heightPixels: 0)
            try await fixture.expectSize(columns: 140, rows: 45)
            #expect(try await fixture.clientSize(identity.terminal) == "140 45")
            await second.channel.resize(columns: 140, rows: 45, widthPixels: 0, heightPixels: 0)
            try await fixture.expectSize(columns: 140, rows: 45)
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 140, rows: 45)

            _ = try await fixture.command("tmux resize-window -t \(fixture.target) -x 55 -y 17")
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            try await Task.sleep(for: .milliseconds(300))
            #expect(try await fixture.windowSize() == "55 17 55 17")
            #expect(try await fixture.command("tmux show-option -w -v -t \(fixture.target) window-size") == "manual")
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func identityRevalidationAndSameSizeActivationPreserveSplitLayout() async throws {
        let fixture = try await TmuxActivationFixture.make()
        do {
            let first = try await fixture.attach(columns: 120, rows: 40)
            let identity = try first.identity()
            _ = try await fixture.attach(columns: 40, rows: 22, integrated: false)
            try await fixture.expectSize(columns: 40, rows: 22)
            let adapter = RemoteTmuxRuntimeDialect(execute: fixture.execute)
            for field in ["terminal", "process", "created", "server", "session", "sessionCreated"] {
                let terminal = field == "terminal" ? "/dev/pts/99999" : identity.terminal
                var update = first.update
                let process = field == "process" ? "\(Int(identity.process)! + 1)" : identity.process
                let created = field == "created" ? "\(Int(identity.created)! + 1)" : identity.created
                update.clientIdentity = "\(terminal):\(process):\(created)"
                let context = try #require(update.active)
                update.active = .init(
                    backend: "tmux", server: field == "server" ? "\(Int(identity.server)! + 1)" : identity.server,
                    session: (field == "session" ? "$99999" : identity.session) + ":"
                        + (field == "sessionCreated"
                            ? "\(Int(identity.sessionCreated)! + 1)" : identity.sessionCreated),
                    pane: context.pane, shellInstance: context.shellInstance)
                let stale = try #require(RemoteTmuxClientIdentity(update: update, terminal: terminal))
                await #expect(throws: TerminalRuntimeError.self) { try await adapter.refreshSize(of: stale) }
                #expect(try await fixture.windowSize() == "40 21 40 21")
            }
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 120, rows: 40)
            _ = try await fixture.command("tmux split-window -h -t \(fixture.target)")
            let layoutCommand = "tmux display-message -p -t \(try fixture.target) '#{window_layout}'"
            let processesCommand = "tmux list-panes -t \(try fixture.target) -F '#{pane_id} #{pane_pid}'"
            let layout = try await fixture.command(layoutCommand)
            let processes = try await fixture.command(processesCommand)
            _ = try await fixture.attach(columns: 120, rows: 40, integrated: false)
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await fixture.command(layoutCommand) == layout)
            #expect(try await fixture.command(processesCommand) == processes)
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["bash", "zsh", "fish"])
    func manualAttachActivationPreservesDraftPrefixCopyModeAndRejectsDetachedClients(shell: String) async throws {
        let fixture = try await TmuxActivationFixture.make(shell: shell)
        do {
            let first = try await fixture.attach(columns: 120, rows: 40, manualShell: shell)
            let identity = try first.identity()
            try await TmuxActivationFixture.wait { first.context?.promptReady == true }
            await first.channel.write(Data("echo draft-not-executed".utf8))
            #expect(try await first.draft() == "echo draft-not-executed")
            _ = try await fixture.attach(columns: 40, rows: 22, integrated: false)
            try await fixture.expectSize(columns: 40, rows: 22)
            let tty = try RemoteTmuxCommands.quote(identity.terminal)
            _ = try await fixture.command("tmux switch-client -c \(tty) -T prefix")
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 120, rows: 40)
            #expect(try await fixture.clientField(identity.terminal, field: "client_key_table") == "prefix")
            _ = try await fixture.command("tmux switch-client -c \(tty) -T root; tmux copy-mode -t \(fixture.target)")
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await fixture.command("tmux display-message -p -t \(fixture.target) '#{pane_in_mode}'") == "1")
            _ = try await fixture.command("tmux send-keys -t \(fixture.target) -X cancel")
            try await TmuxActivationFixture.wait { first.context?.capabilities.contains(.readDraft) == true }
            #expect(try await first.draft() == "echo draft-not-executed")

            let adapter = RemoteTmuxRuntimeDialect(execute: fixture.execute)
            for flag in ["ignore-size", "read-only", "active-pane"] {
                _ = try await fixture.command("tmux refresh-client -t \(tty) -f \(flag)")
                await #expect(throws: TerminalRuntimeError.self) { try await adapter.refreshSize(of: identity) }
                if flag == "read-only" {
                    _ = try await fixture.command("tmux switch-client -c \(tty) -r")
                } else {
                    _ = try await fixture.command("tmux refresh-client -t \(tty) -f '!\(flag)'")
                }
            }
            _ = try await fixture.command("tmux detach-client -t \(tty)")
            try await TmuxActivationFixture.wait { first.update.status == .ordinary }
            await #expect(throws: TerminalRuntimeError.self) { try await adapter.refreshSize(of: identity) }
            first.output.removeAll()
            await first.channel.setTerminalActive(false)
            await first.channel.setTerminalActive(true)
            await first.channel.write(Data("printf 'OUTER-%s\\n' SHELL-OK\n".utf8))
            try await TmuxActivationFixture.wait {
                String(decoding: first.output, as: UTF8.self).contains("OUTER-SHELL-OK")
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func activationDoesNotInterruptVimOrChangeItsPaneProcess() async throws {
        let fixture = try await TmuxActivationFixture.make()
        let path = "/tmp/termind-vim-activation-\(UUID().uuidString)"
        do {
            let first = try await fixture.attach(columns: 120, rows: 40)
            let launch = try RemoteTmuxCommands.quote(
                "vim -n -u NONE -i NONE -c 'call setline(1, \"activation-buffer\")' \(path)")
            _ = try await fixture.command("tmux send-keys -t \(fixture.target) \(launch) Enter")
            try await TmuxActivationFixture.wait {
                try await fixture.command("tmux capture-pane -p -t \(fixture.target)").hasPrefix("activation-buffer\n")
            }
            let pid = try await fixture.command("tmux display-message -p -t \(fixture.target) '#{pane_pid}'")
            _ = try await fixture.attach(columns: 40, rows: 22, integrated: false)
            try await fixture.expectSize(columns: 40, rows: 22)
            await first.channel.setTerminalActive(true)
            try await fixture.expectSize(columns: 120, rows: 40)
            #expect(try await fixture.command("tmux display-message -p -t \(fixture.target) '#{pane_pid}'") == pid)
            #expect(
                try await fixture.command("tmux display-message -p -t \(fixture.target) '#{pane_current_command}'")
                    == "vim")
            _ = try await fixture.command("tmux send-keys -t \(fixture.target) ':w' Enter")
            try await TmuxActivationFixture.wait {
                try await fixture.execute("test -f \(path)").exitCode == 0
            }
            #expect(try await fixture.command("cat \(path)") == "activation-buffer")
            _ = try await fixture.command("rm \(path)")
            await fixture.close()
        } catch {
            _ = try? await fixture.command("rm -f \(path)")
            await fixture.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func missingIntegrationAndSingleChannelCapacityLeaveInputUsable() async throws {
        let fixture = try await TmuxActivationFixture.make()
        do {
            for (integrated, maximumChannels) in [(false, 8), (true, 1)] {
                let first = try await fixture.attach(
                    columns: 120, rows: 40, integrated: integrated, maximumChannels: maximumChannels)
                let second = try await fixture.attach(columns: 40, rows: 22, integrated: false)
                try await fixture.expectSize(columns: 40, rows: 22)
                await first.channel.setTerminalActive(true)
                try await Task.sleep(for: .seconds(1))
                try await fixture.expectSize(columns: 40, rows: 22)
                #expect(first.update.status != .multiplexer)
                await first.channel.write(Data("printf 'INPUT-%s\\n' STILL-WORKS\n".utf8))
                try await fixture.expectSize(columns: 120, rows: 40)
                try await TmuxActivationFixture.wait {
                    String(decoding: first.output, as: UTF8.self).contains("INPUT-STILL-WORKS")
                }
                await first.channel.disconnect()
                await second.channel.disconnect()
            }
            await fixture.close()
        } catch {
            await fixture.close()
            throw error
        }
    }
}

@MainActor
final class TmuxActivationFixture {
    struct Configuration: Decodable {
        let port: Int
        let hostFingerprint: String
        let privateKeyPath: String
    }

    final class Client {
        var output = Data()
        var update = TerminalRuntimeUpdate(status: .unknown)
        private let maximumChannels: Int
        lazy var channel = SSHPTYChannel(
            output: { [weak self] data in
                Task { @MainActor in
                    self?.output.append(data)
                }
            }, exit: { _ in },
            shellIntegration: { [weak self] event in
                Task { @MainActor in
                    if case .runtime(let update) = event { self?.update = update }
                }
            }, maxSessionsPolicy: .init(preferences: .init(maxSessions: maximumChannels)))

        init(maximumChannels: Int) { self.maximumChannels = maximumChannels }

        func identity() throws -> RemoteTmuxClientIdentity {
            let terminal = try #require(update.clientIdentity?.split(separator: ":").first.map(String.init))
            return try #require(RemoteTmuxClientIdentity(update: update, terminal: terminal))
        }

        var context: TerminalShellContext? {
            update.contexts.first { $0.identity == update.active }
        }

        func draft() async throws -> String {
            // Prefix/copy-mode changes reach the runtime snapshot asynchronously.
            for _ in 0..<100 {
                if let context, context.capabilities.contains(.readDraft) {
                    do { return try await channel.contextDraft(context) } catch TerminalRuntimeError.staleContext {
                    } catch TerminalRuntimeError.capacityUnavailable {}
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw TerminalRuntimeError.staleContext
        }
    }

    let configuration: Configuration
    let control = SSHPTYChannel(output: { _ in }, exit: { _ in })
    private(set) var execute: RemoteSessionCommandExecutor!
    private var reference: RemoteSessionReference!
    private var clients: [Client] = []
    var target: String { get throws { try RemoteTmuxCommands.quote(reference.session.id) } }

    private init(configuration: Configuration) { self.configuration = configuration }

    func attachment(hostID: UUID) -> RemoteSessionReference {
        .init(
            backend: .tmux, session: reference.session, hostID: hostID,
            endpoint: "127.0.0.1:\(configuration.port)", username: "root", ownershipToken: reference.ownershipToken)
    }

    static func make(shell: String = "bash") async throws -> TmuxActivationFixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"])
        let configuration = try JSONDecoder().decode(
            Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let fixture = TmuxActivationFixture(configuration: configuration)
        do {
            try await fixture.connect(fixture.control, columns: 80, rows: 24, integrated: false)
            try await fixture.control.releaseTerminalForControl()
            fixture.execute = try await fixture.control.sessionCommandExecutor()
            let token = UUID()
            let session = try await RemoteSessionBackendRegistry.live.backend(.tmux, execute: fixture.execute).create(
                token: token, startupCommand: nil, shellIntegration: true,
                environment: [.init(variable: "SHELL", value: "/bin/\(shell)")])
            fixture.reference = .init(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: token)
            return fixture
        } catch {
            await fixture.close()
            throw error
        }
    }

    func attach(
        columns: UInt16, rows: UInt16, manualShell: String? = nil, integrated: Bool = true, maximumChannels: Int = 8
    ) async throws -> Client {
        let client = Client(maximumChannels: maximumChannels)
        clients.append(client)
        if let manualShell {
            await client.channel.configureEnvironment([
                .init(variable: "SHELL", value: "/bin/\(manualShell)"),
                .init(variable: "TERMIND_TMUX_SHELL", value: "/bin/\(manualShell)"),
            ])
        } else {
            let command = try RemoteTmuxCommands.attach(reference)
            await client.channel.configureStartup { _ in .init(command: command) }
        }
        try await connect(client.channel, columns: columns, rows: rows, integrated: integrated)
        if manualShell != nil {
            try await Self.wait { client.update.status == .ordinary }
            await client.channel.write(Data("tmux attach-session -t \(try target)\n".utf8))
        }
        if integrated, maximumChannels > 1 {
            try await Self.wait { client.update.status == .multiplexer }
        }
        return client
    }

    func connect(_ channel: SSHPTYChannel, columns: UInt16, rows: UInt16, integrated: Bool) async throws {
        let key = try String(contentsOfFile: configuration.privateKeyPath, encoding: .utf8)
        try await channel.connect(
            using: SSHConnectionRequest(
                configuration: .init(
                    hostID: UUID(), host: "127.0.0.1", port: configuration.port, username: "root",
                    credentials: [.privateKey(privateKey: SSHSecret(key), publicKey: nil, passphrase: nil)],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: configuration.hostFingerprint)])),
            shellIntegrationEnabled: integrated, columns: columns, rows: rows)
    }

    func command(_ command: String) async throws -> String {
        let result = try await execute(command)
        try #require(result.exitCode == 0 && !result.truncated, "Fixture command failed: \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .newlines)
    }

    func windowSize() async throws -> String {
        try await command(
            "tmux display-message -p -t \(target) '#{window_width} #{window_height} #{pane_width} #{pane_height}'")
    }

    func clientField(_ terminal: String, field: String) async throws -> String {
        try await command(
            "tmux list-clients -F '#{client_tty}|#{\(field)}' | awk -F '|' -v tty=\(RemoteTmuxCommands.quote(terminal)) '$1 == tty {print $2}'"
        )
    }

    func clientSize(_ terminal: String) async throws -> String {
        try await command(
            "tmux list-clients -F '#{client_tty}|#{client_width} #{client_height}' | awk -F '|' -v tty=\(RemoteTmuxCommands.quote(terminal)) '$1 == tty {print $2}'"
        )
    }

    func expectSize(columns: UInt16, rows: UInt16) async throws {
        let expected = "\(columns) \(rows - 1) \(columns) \(rows - 1)"
        try await Self.wait { try await self.windowSize() == expected }
        #expect(try await windowSize() == expected)
    }

    static func wait(
        sourceLocation: SourceLocation = #_sourceLocation, _ predicate: () async throws -> Bool
    ) async throws {
        for _ in 0..<200 {
            if try await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try await predicate(), "Timed out waiting for the fixture", sourceLocation: sourceLocation)
    }

    func close() async {
        for client in clients { await client.channel.disconnect() }
        if let reference, let execute {
            try? await RemoteSessionBackendRegistry.live.backend(.tmux, execute: execute).terminate(reference)
        }
        await control.disconnect()
    }
}

import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"] != nil), .serialized)
@MainActor
struct TerminalContextRuntimeTests {
    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
        let privateKeyPath: String
        let maxSessions: Int?
    }

    private final class State {
        let coordinator = TerminalContextCoordinator()
        var events: [TerminalContextEvent] = []
        var output = Data()
        var reference: RemoteSessionReference?
        var directoryInvalidations = 0

        func receive(_ event: SSHShellIntegrationEvent) {
            if case .runtime(let update) = event {
                let hadDirectory = coordinator.directory != nil
                events += coordinator.receive(update, generation: coordinator.generation)
                if hadDirectory, coordinator.directory == nil { directoryInvalidations += 1 }
            }
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["bash", "zsh", "fish"])
    func managedHistoryReadsTheConfirmedPaneFileWithoutTerminalInput(shell: String) async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) > 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        let root = "/tmp/termind-history-\(UUID().uuidString)"
        let firstPath = shell == "fish" ? root + "/fish/pane-a_history" : root + "/a ' history"
        let secondPath = shell == "fish" ? root + "/fish/pane-b_history" : root + "/b ' history"
        let setup = """
            mkdir -p \(try RemoteTmuxCommands.quote(root + "/fish"))
            printf %s \(try RemoteTmuxCommands.quote(historyContents("echo from-pane-a", shell: shell))) > \(try RemoteTmuxCommands.quote(firstPath))
            printf %s \(try RemoteTmuxCommands.quote(historyContents("echo from-pane-b", shell: shell))) > \(try RemoteTmuxCommands.quote(secondPath))
            """
        await channel.configureStartup { execute in
            _ = try await execute(setup)
            let backend = RemoteMultiplexerService(execute: execute)
            let owner = UUID()
            let session = try await backend.create(
                token: owner, startupCommand: nil, shellIntegration: true,
                environment: [
                    .init(variable: "SHELL", value: "/bin/\(shell)"),
                    .init(variable: "HISTFILE", value: firstPath),
                    .init(variable: "XDG_DATA_HOME", value: root),
                    .init(variable: "fish_history", value: "pane-a"),
                ])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: owner)
            await MainActor.run { state.reference = reference }
            return try SSHPTYStartupPlan(command: backend.launch(reference, created: true).command)
        }
        do {
            try await connect(channel, fixture)
            try await wait { state.coordinator.active?.promptReady == true }
            let first = try #require(state.coordinator.active)
            #expect(first.historySource?.path == firstPath)
            let firstLoader = RemoteShellHistoryLoader(channel: channel, charset: .utf8, context: first)
            #expect(try await firstLoader.load(source: nil).map(\.command) == ["echo from-pane-a"])
            let execute = try await channel.runtimeCommandExecutor()
            _ = try await execute(
                "tmux split-window -h -t \(try RemoteTmuxCommands.quote(first.identity.pane))"
                    + " -e \(try RemoteTmuxCommands.quote("HISTFILE=" + secondPath)) -e fish_history=pane-b")
            try await wait {
                state.coordinator.active?.identity != first.identity && state.coordinator.active?.promptReady == true
            }
            let second = try #require(state.coordinator.active)
            #expect(second.historySource?.path == secondPath)
            await #expect(throws: TerminalRuntimeError.self) { try await firstLoader.load(source: nil) }
            let secondLoader = RemoteShellHistoryLoader(channel: channel, charset: .utf8, context: second)
            #expect(try await secondLoader.load(source: nil).map(\.command) == ["echo from-pane-b"])
            _ = try await execute("rm -rf \(try RemoteTmuxCommands.quote(root))")
            try await cleanup(channel, state)
        } catch {
            if let execute = try? await channel.sessionCommandExecutor() {
                _ = try? await execute("rm -rf \(try RemoteTmuxCommands.quote(root))")
            }
            try? await cleanup(channel, state)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(2)), arguments: ["bash", "zsh", "fish"])
    func managedContextsDraftsAndInvisibleCompletions(shell: String) async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) > 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        var stage = "connect"
        await channel.configureStartup { execute in
            let backend = RemoteMultiplexerService(execute: execute)
            let owner = UUID()
            let session = try await backend.create(
                token: owner, startupCommand: "cd /tmp", shellIntegration: true,
                environment: [
                    .init(variable: "SHELL", value: "/bin/\(shell)"),
                    .init(variable: "LC_ALL", value: "C.UTF-8"),
                ])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: owner)
            await MainActor.run { state.reference = reference }
            return try SSHPTYStartupPlan(command: backend.launch(reference, created: true).command)
        }
        do {
            try await connect(channel, fixture)
            stage = "initial prompt"
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == true }
            let first = try #require(state.coordinator.active)
            #expect(first.shell == shell)
            #expect(first.directory == "/tmp")
            let execute = try await channel.runtimeCommandExecutor()
            stage = "read draft"
            let beforeInput = state.coordinator.revision
            let invalidations = state.directoryInvalidations
            state.coordinator.noteInput()
            await channel.write(Data("echo 'draft | 中文'".utf8))
            try await wait {
                state.coordinator.revision > beforeInput && state.coordinator.active?.identity == first.identity
            }
            let draftContext = try #require(state.coordinator.active)
            #expect(try await channel.contextDraft(draftContext) == "echo 'draft | 中文'")
            try await wait { (state.coordinator.active?.sequence ?? 0) > draftContext.sequence }
            #expect(state.coordinator.directory == "/tmp")
            #expect(state.directoryInvalidations == invalidations)
            stage = "prefix mode"
            state.coordinator.noteInput()
            await channel.write(Data([0x02]))
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == false }
            #expect(state.coordinator.directory == "/tmp")
            #expect(state.directoryInvalidations == invalidations)
            state.coordinator.noteInput()
            await channel.write(Data([0x1B]))
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == true }
            #expect(state.directoryInvalidations == invalidations)
            let resumedContext = try #require(state.coordinator.active)
            #expect(try await channel.contextDraft(resumedContext) == "echo 'draft | 中文'")
            try await wait { (state.coordinator.active?.sequence ?? 0) > resumedContext.sequence }
            stage = "replace draft"
            let replacementContext = try #require(state.coordinator.active)
            #expect(
                try await channel.contextDraft(replacementContext, replacing: "printf 'replacement'")
                    == "printf 'replacement'")
            try await wait { (state.coordinator.active?.sequence ?? 0) > replacementContext.sequence }
            let editedElsewhere = try #require(state.coordinator.active)
            _ = try await execute("tmux send-keys -t '\(first.identity.pane)' -l 'remote-edit'")
            do {
                _ = try await channel.contextDraft(editedElsewhere, replacing: "MUST_NOT_REPLACE_REMOTE_EDIT")
                Issue.record("A draft changed by another client must not be replaced")
            } catch {}
            let beforeClear = state.coordinator.revision
            state.coordinator.noteInput()
            await channel.write(Data([0x15]))
            try await wait {
                state.coordinator.revision > beforeClear && state.coordinator.active?.identity == first.identity
            }
            stage = "split pane"
            let target = try RemoteTmuxCommands.quote(first.identity.pane)
            let split = try await execute("tmux split-window -h -P -F '#{pane_id}' -t \(target)")
            let second = split.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(RemoteShellContextRecord.validPane(second))
            try await wait {
                state.coordinator.active?.identity.pane == second && state.coordinator.active?.promptReady == true
            }
            #expect(state.coordinator.contexts.count == 2)
            stage = "background command"
            _ = try await execute("tmux send-keys -t \(target) 'sleep 2; false' Enter")
            try await wait {
                state.events.contains {
                    $0.context == first.identity
                        && {
                            if case .commandStarted = $0.payload { return true }
                            return false
                        }($0)
                }
            }
            try await wait {
                state.events.contains {
                    $0.context == first.identity
                        && {
                            if case .commandFinished(1, _) = $0.payload { return true }
                            return false
                        }($0)
                }
            }
            #expect(state.coordinator.active?.identity.pane == second)
            stage = "unsafe modes"
            _ = try await execute("tmux copy-mode -t '\(second)'")
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == false }
            #expect(state.coordinator.directory == state.coordinator.active?.directory)
            #expect(state.coordinator.ticket(requiring: .directory) == nil)
            _ = try await execute(
                "tmux send-keys -t '\(second)' -X cancel; tmux set-window-option -t '\(second)' synchronize-panes on")
            try await Task.sleep(for: .seconds(1))
            #expect(state.coordinator.active?.capabilities.contains(.replaceDraft) == false)
            _ = try await execute("tmux set-window-option -t '\(second)' synchronize-panes off")
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == true }
            let terminal = try #require(state.coordinator.clientIdentity?.components(separatedBy: ":").first)
            let client = try RemoteTmuxCommands.quote(terminal)
            _ = try await execute("tmux refresh-client -t \(client) -f active-pane")
            try await wait { state.coordinator.status == .unavailable }
            _ = try await execute("tmux refresh-client -t \(client) -f '!active-pane'")
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == true }
            let stale = try #require(state.coordinator.active)
            _ = try await execute("tmux select-pane -t \(target)")
            do {
                _ = try await channel.contextDraft(stale, replacing: "MUST_NOT_APPEAR")
                Issue.record("A silently switched pane must reject the old draft target")
            } catch {}
            #expect(
                try await execute("tmux capture-pane -p -t '\(second)'").stdout.contains("MUST_NOT_APPEAR") == false)
            stage = "window switch"
            let sessionTarget = try RemoteTmuxCommands.quote(state.reference!.session.id)
            let window = try await execute("tmux new-window -t \(sessionTarget) -P -F '#{pane_id}'")
            let third = window.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            try #require(RemoteShellContextRecord.validPane(third))
            try await wait {
                state.coordinator.active?.identity.pane == third && state.coordinator.active?.promptReady == true
            }
            _ = try await execute("tmux send-keys -t '\(third)' 'cd /' Enter")
            try await wait { state.coordinator.directory == "/" }
            _ = try await execute("tmux select-window -t \(target); tmux select-pane -t \(target)")
            try await wait {
                state.coordinator.active?.identity == first.identity && state.coordinator.directory == "/tmp"
            }
            stage = "reconnect without hook reinstallation"
            let reference = try #require(state.reference)
            await channel.disconnect()
            state.coordinator.reset()
            state.events.removeAll()
            await channel.configureStartup { execute in
                let backend = RemoteMultiplexerService(execute: execute)
                try backend.validate(reference)
                return try SSHPTYStartupPlan(command: backend.launch(reference, created: false).command)
            }
            try await connect(channel, fixture)
            try await wait { state.coordinator.active?.capabilities.contains(.readDraft) == true }
            #expect(state.coordinator.contexts[first.identity] != nil)
            #expect(state.events.isEmpty)
            try await cleanup(channel, state)
        } catch {
            Issue.record("Runtime acceptance failed at \(stage) for \(shell): \(error)")
            try? await cleanup(channel, state)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["bash", "zsh", "fish"])
    func ordinaryShellManualAttachAndDetachUseTheSameTransport(shell: String) async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) > 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        let root = "/tmp/termind-manual-history-\(UUID().uuidString)"
        let path = shell == "fish" ? root + "/fish/manual_history" : root + "/history"
        var stage = "ordinary draft"
        await channel.configureEnvironment([
            .init(variable: "TERMIND_TMUX_SHELL", value: "/bin/\(shell)"), .init(variable: "LC_ALL", value: "C.UTF-8"),
        ])
        do {
            try await connect(channel, fixture)
            try await wait { state.coordinator.status == .ordinary && state.coordinator.active?.promptReady == true }
            let outer = try #require(state.coordinator.active)
            #expect(outer.shell == shell)
            await channel.write(Data("echo scratch".utf8))
            #expect(try await channel.contextDraft(outer) == "echo scratch")
            await channel.write(Data([0x15]))
            stage = "ordinary history"
            let outerHistory = RemoteShellHistoryLoader(channel: channel, charset: .utf8, context: outer)
            _ = try await outerHistory.load(source: nil)
            await #expect(throws: TerminalRuntimeError.self) {
                try await RemoteShellHistoryLoader(channel: channel, charset: .utf8).load(source: nil)
            }
            stage = "ordinary running cwd"
            let cwd = try #require(state.coordinator.directory)
            let invalidations = state.directoryInvalidations
            await channel.write(Data("sleep 2\n".utf8))
            try await wait { state.coordinator.active?.promptReady == false }
            #expect(state.coordinator.directory == cwd)
            #expect(state.coordinator.ticket(requiring: .replaceDraft) == nil)
            try await wait { state.coordinator.active?.promptReady == true }
            #expect(state.directoryInvalidations == invalidations)
            #expect(state.coordinator.directory == cwd)
            let execute = try await channel.runtimeCommandExecutor()
            _ = try await execute(
                "mkdir -p \(try RemoteTmuxCommands.quote(root + "/fish")); printf %s "
                    + "\(try RemoteTmuxCommands.quote(historyContents("echo manual-pane", shell: shell)))"
                    + " > \(try RemoteTmuxCommands.quote(path))")
            let backend = RemoteMultiplexerService(execute: execute)
            let owner = UUID()
            let session = try await backend.create(
                token: owner, startupCommand: "cd /tmp", shellIntegration: true,
                environment: [
                    .init(variable: "SHELL", value: "/bin/\(shell)"),
                    .init(variable: "HISTFILE", value: path),
                    .init(variable: "XDG_DATA_HOME", value: root),
                    .init(variable: "fish_history", value: "manual"),
                ])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: owner)
            state.reference = reference
            stage = "manual attach history"
            await channel.write(Data("tmux attach-session -t '\(session.id)'\n".utf8))
            try await wait { state.coordinator.status == .multiplexer && state.coordinator.active?.promptReady == true }
            #expect(state.coordinator.directory == "/tmp")
            let pane = try #require(state.coordinator.active)
            #expect(pane.historySource?.path == path)
            let paneHistory = RemoteShellHistoryLoader(channel: channel, charset: .utf8, context: pane)
            #expect(try await paneHistory.load(source: nil).map(\.command) == ["echo manual-pane"])
            if outer.historySource?.path == "" {
                #expect(try await outerHistory.load(source: nil).isEmpty)
            } else {
                await #expect(throws: TerminalRuntimeError.self) { try await outerHistory.load(source: nil) }
            }
            await channel.write(Data([0x02, 0x64]))
            stage = "detach history"
            try await wait { state.coordinator.status == .ordinary }
            #expect(state.coordinator.active?.identity == outer.identity)
            _ = try await outerHistory.load(source: nil)
            await #expect(throws: TerminalRuntimeError.self) { try await paneHistory.load(source: nil) }
            #expect(
                state.events.contains {
                    if case .commandFinished = $0.payload { return $0.context == outer.identity }
                    return false
                })
            _ = try await execute("rm -rf \(try RemoteTmuxCommands.quote(root))")
            try await cleanup(channel, state)
        } catch {
            Issue.record("Manual history acceptance failed at \(stage) for \(shell): \(error)")
            if let execute = try? await channel.sessionCommandExecutor() {
                _ = try? await execute("rm -rf \(try RemoteTmuxCommands.quote(root))")
            }
            try? await cleanup(channel, state)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func capacityFailureLeavesTheTerminalUsable() async throws {
        let fixture = try loadFixture()
        let state = State()
        let channel = SSHPTYChannel(
            output: { data in Task { @MainActor in state.output.append(data) } }, exit: { _ in },
            shellIntegration: { event in Task { @MainActor in state.receive(event) } },
            maxSessionsPolicy: .init(preferences: .init(maxSessions: 1)))
        do {
            try await connect(channel, fixture)
            try await wait { state.coordinator.status == .ordinary }
            let context = try #require(state.coordinator.active)
            do {
                _ = try await channel.contextDraft(context)
                Issue.record("The occupied channel budget must refuse a draft exec")
            } catch {}
            do {
                _ = try await RemoteShellHistoryLoader(channel: channel, charset: .utf8, context: context)
                    .load(source: nil)
                Issue.record("The occupied channel budget must refuse a history exec")
            } catch {}
            await channel.write(Data("printf 'TERMINAL_STILL_WORKS\\n'\n".utf8))
            try await wait { String(decoding: state.output, as: UTF8.self).contains("TERMINAL_STILL_WORKS\r\n") }
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func serverChannelRefusalLeavesTerminalUsable() async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) == 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        await channel.configureStartup { execute in
            let backend = RemoteMultiplexerService(execute: execute)
            let owner = UUID()
            let session = try await backend.create(token: owner, startupCommand: nil, shellIntegration: true)
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: owner)
            await MainActor.run { state.reference = reference }
            return try SSHPTYStartupPlan(command: backend.launch(reference, created: true).command)
        }
        do {
            try await connect(channel, fixture)
            try await wait { state.coordinator.status == .unavailable }
            #expect(state.coordinator.directory == nil)
            #expect(state.coordinator.ticket(requiring: .replaceDraft) == nil)
            await #expect(throws: TerminalRuntimeError.self) {
                try await RemoteShellHistoryLoader(channel: channel, charset: .utf8).load(source: nil)
            }
            await channel.write(Data("printf 'SERVER_LIMIT_%s\\n' TERMINAL_OK\n".utf8))
            try await wait { String(decoding: state.output, as: UTF8.self).contains("SERVER_LIMIT_TERMINAL_OK") }
            try await cleanup(channel, state)
        } catch {
            try? await cleanup(channel, state)
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func plainShellHistoryStillLoadsWithoutIntegration(prepared: Bool) async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) > 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        if prepared { await channel.configureStartup { _ in nil } }
        do {
            try await connect(channel, fixture, shellIntegrationEnabled: false)
            _ = try await RemoteShellHistoryLoader(channel: channel, charset: .utf8).load(source: nil)
            await channel.disconnect()
        } catch {
            await channel.disconnect()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loginScriptAutoAttachNeverReceivesBootstrapInput() async throws {
        let fixture = try loadFixture()
        guard (fixture.maxSessions ?? 1) > 1 else { return }
        let state = State()
        let channel = makeChannel(state)
        let backup = "/tmp/termind-profile-\(UUID().uuidString)"
        let restore = """
            if [ -f '\(backup)' ]; then mv '\(backup)' /root/.bash_profile;
            else rm -f /root/.bash_profile; fi
            """
        await channel.configureStartup { execute in
            let backend = RemoteMultiplexerService(execute: execute)
            let owner = UUID()
            let session = try await backend.create(
                token: owner, startupCommand: "exec vim -n -u NONE -i NONE", shellIntegration: true,
                environment: [.init(variable: "SHELL", value: "/bin/bash")])
            let reference = RemoteSessionReference(
                backend: .tmux, session: session, hostID: UUID(), endpoint: "fixture", username: "root",
                ownershipToken: owner)
            await MainActor.run { state.reference = reference }
            let profile = try RemoteTmuxCommands.quote("exec tmux attach-session -t '\(session.id)'")
            _ = try await execute(
                "[ ! -f /root/.bash_profile ] || cp /root/.bash_profile '\(backup)'; printf '%s\\n' \(profile) > /root/.bash_profile"
            )
            return nil
        }
        do {
            try await connect(channel, fixture)
            let execute = try await channel.runtimeCommandExecutor()
            let reference = try #require(state.reference)
            let target = try RemoteTmuxCommands.quote(reference.session.id)
            var attached = false
            for _ in 0..<100 {
                attached =
                    try await execute("tmux list-clients -t \(target) -F '#{client_pid}'").stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                if attached { break }
                try await Task.sleep(for: .milliseconds(25))
            }
            _ = try await execute(restore)
            try #require(attached)
            try await Task.sleep(for: .seconds(1))
            let before = try await execute("tmux capture-pane -p -t \(target)").stdout
            try await Task.sleep(for: .seconds(2))
            let after = try await execute("tmux capture-pane -p -t \(target)").stdout
            #expect(before == after)
            #expect(!after.contains("__termind_"))
            #expect(
                try await execute("tmux display-message -p -t \(target) '#{pane_current_command}'").stdout == "vim\n")
            #expect(state.coordinator.directory == nil)
            #expect(state.coordinator.ticket(requiring: .replaceDraft) == nil)
            try await cleanup(channel, state)
        } catch {
            if let execute = try? await channel.sessionCommandExecutor() { _ = try? await execute(restore) }
            try? await cleanup(channel, state)
            throw error
        }
    }

    private func historyContents(_ command: String, shell: String) -> String {
        switch shell {
        case "zsh": ": 123:0;\(command)\n"
        case "fish": "- cmd: \(command)\n  when: 123\n"
        default: "#123\n\(command)\n"
        }
    }

    private func makeChannel(_ state: State) -> SSHPTYChannel {
        SSHPTYChannel(
            output: { data in Task { @MainActor in state.output.append(data) } }, exit: { _ in },
            shellIntegration: { event in Task { @MainActor in state.receive(event) } })
    }

    private func cleanup(_ channel: SSHPTYChannel, _ state: State) async throws {
        try await channel.releaseTerminalForControl()
        if let reference = state.reference {
            let execute = try await channel.sessionCommandExecutor()
            try await RemoteMultiplexerService(execute: execute).terminate(reference)
        }
        await channel.disconnect()
    }

    private func loadFixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_TMUX_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TerminalRuntimeError.invalidResponse
    }

    private func connect(
        _ channel: SSHPTYChannel, _ fixture: Fixture, shellIntegrationEnabled: Bool = true
    ) async throws {
        let key = try String(contentsOfFile: fixture.privateKeyPath, encoding: .utf8)
        try await channel.connect(
            using: SSHConnectionRequest(
                configuration: .init(
                    hostID: UUID(), host: "127.0.0.1", port: fixture.port, username: "root",
                    credentials: [.privateKey(privateKey: SSHSecret(key), publicKey: nil, passphrase: nil)],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: fixture.hostFingerprint)])),
            shellIntegrationEnabled: shellIntegrationEnabled, columns: 100, rows: 30)
    }
}

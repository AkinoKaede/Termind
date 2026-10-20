// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

/// Uses real binaries and SSH PTYs in the disposable fixture, never a user's sessions.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_MULTIPLEXER_FIXTURE"] != nil), .serialized)
@MainActor
struct NativeMultiplexerRuntimeTests {
    private struct Fixture: Decodable {
        let port: Int
        let hostFingerprint: String
        let privateKeyPath: String

        func request() throws -> SSHConnectionRequest {
            let key = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
            return SSHConnectionRequest(
                configuration: .init(
                    hostID: UUID(), host: "127.0.0.1", port: port, username: "root",
                    credentials: [.privateKey(privateKey: SSHSecret(key), publicKey: nil, passphrase: nil)],
                    expectedHostKeys: [.init(algorithm: .ed25519, fingerprint: hostFingerprint)]))
        }
    }

    private final class State {
        let context = TerminalContextCoordinator()
        var output = Data()

        func channel() -> SSHPTYChannel {
            SSHPTYChannel(
                output: { data in Task { @MainActor in self.output.append(data) } }, exit: { _ in },
                shellIntegration: { event in
                    Task { @MainActor in
                        if case .runtime(let update) = event {
                            self.context.receive(update, generation: self.context.generation)
                        }
                    }
                })
        }
    }

    @Test(.timeLimit(.minutes(3)), arguments: SessionPersistenceBackendID.supported, [false, true])
    func manualAndManagedDirectoriesSurviveOtherSessionsPaneChangesAndReconnect(
        backendID: SessionPersistenceBackendID, managed: Bool
    ) async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_MULTIPLEXER_FIXTURE"])
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let hostID = UUID()
        let control = SSHPTYChannel(output: { _ in }, exit: { _ in })
        await control.configureStartup { _ in nil }
        try await connect(control, fixture: fixture)
        try await control.releaseTerminalForControl()
        let execute = try await control.sessionCommandExecutor()
        let backend = try RemoteSessionBackendRegistry.live.backend(backendID, execute: execute)
        let root = "/tmp/termind-wire-" + UUID().uuidString.prefix(8).lowercased()
        let names = [
            "native-" + UUID().uuidString.prefix(8).lowercased(), "other-" + UUID().uuidString.prefix(8).lowercased(),
        ]
        var owned: [RemoteSessionReference] = []
        var nativeNames: [String] = []
        var clients: [SSHPTYChannel] = []
        var states: [State] = []
        var stage = "create"

        func cleanup() async {
            for client in clients { await client.disconnect() }
            for reference in owned { try? await backend.terminate(reference) }
            for name in nativeNames { _ = try? await execute(nativeStop(backendID, root: root, name: name)) }
            _ = try? await execute("rm -rf \(try RemoteMultiplexerCommands.quote(root))")
            await control.disconnect()
        }

        do {
            for (index, name) in names.enumerated() {
                let directory = index == 0 ? "/tmp" : "/etc"
                if managed {
                    let token = UUID()
                    let session = try await backend.create(
                        token: token, startupCommand: "cd \(directory)", shellIntegration: true,
                        environment: [.init(variable: "SHELL", value: "/bin/bash")])
                    owned.append(
                        .init(
                            backend: backendID, session: session, hostID: hostID,
                            endpoint: "fixture", username: "root", ownershipToken: token))
                } else {
                    nativeNames.append(name)
                    let result = try await execute(
                        nativeCreate(backendID, root: root, name: name, directory: directory))
                    try #require(result.exitCode == 0, "\(result.stderr)")
                }
            }

            // An unrelated attached client must not force a global singleton restriction.
            stage = "unrelated client"
            let other = State()
            states.append(other)
            let otherClient = other.channel()
            clients.append(otherClient)
            try await attach(
                otherClient, state: other, fixture: fixture, backend: backend,
                reference: managed ? owned[1] : nil, root: root, name: names[1])
            try await wait { other.context.directory == "/etc" }

            for pass in 0..<2 {
                stage = pass == 0 ? "initial attach" : "reconnect"
                let state = State()
                states.append(state)
                let channel = state.channel()
                clients.append(channel)
                let reference = managed ? owned[0] : nil
                try await attach(
                    channel, state: state, fixture: fixture, backend: backend,
                    reference: reference, root: root, name: names[0])
                try await wait {
                    state.context.active?.identity.backend == backendID.rawValue
                        && state.context.directory == (pass == 0 ? "/tmp" : "/var")
                        && (!managed || state.context.active?.directorySource == .shell)
                }
                if managed {
                    #expect(state.context.active?.directorySource == .shell)
                } else {
                    #expect(
                        state.context.active?.directorySource
                            == (backendID == .tmux || backendID == .zellij ? .nativePane : .process))
                    #expect(state.context.active?.capabilities.isEmpty == true)
                    #expect(state.context.active?.historySource == nil)
                }

                stage = "cd and revalidate, pass \(pass + 1)"
                let nextDirectory = pass == 0 ? "/var" : "/usr"
                await channel.write(Data("cd \(nextDirectory)\r".utf8))
                try await wait {
                    state.context.directory == nextDirectory
                        && (!managed
                            || (state.context.active?.promptReady == true
                                && state.context.active?.capabilities.contains(.directory) == true))
                }
                let expected = try #require(state.context.active)
                do {
                    try await channel.confirmContext(expected)
                } catch {
                    print("Revalidation expected: \(expected)\nLatest: \(String(describing: state.context.active))")
                    if let client = state.context.clientIdentity, UInt64(client) != nil {
                        let tty = try await execute("ps -p \(client) -o tty= | tr -d ' \\n'")
                        let observed = try? await RemoteMultiplexerRuntimeAdapter(
                            attachment: reference, execute: execute
                        ).inspect(terminal: "/dev/" + tty.stdout)
                        print("Fresh observation: \(String(describing: observed))")
                    }
                    throw error
                }
                #expect(other.context.directory == "/etc")

                if pass == 0 {
                    stage = "pane change"
                    try await verifyPaneChange(
                        backendID, channel: channel, state: state, reference: reference, root: root,
                        name: names[0], execute: execute)
                    // A transport loss must leave the native session available to the next client.
                    await channel.disconnect()
                } else {
                    stage = "detach"
                    await channel.write(Data(detachKeys(backendID)))
                    if !managed {
                        try await wait {
                            state.context.status == .ordinary && state.context.active?.promptReady == true
                        }
                        #expect(state.context.directory == "/root")
                    }
                    await channel.disconnect()
                }
            }
            stage = "owned close"
            for client in clients { await client.disconnect() }
            for reference in owned {
                try await backend.terminate(reference)
                #expect(try await backend.sessions().allSatisfy { !backend.matches(reference, session: $0) })
            }
            owned.removeAll()
            for name in nativeNames {
                let result = try await execute(nativeStop(backendID, root: root, name: name))
                #expect(result.exitCode == 0)
            }
            nativeNames.removeAll()
            await cleanup()
        } catch {
            for state in states {
                print(
                    """
                    \(backendID.rawValue) \(managed ? "managed" : "manual") at \(stage):
                    status=\(state.context.status), issue=\(String(describing: state.context.issue)),
                    active=\(String(describing: state.context.active))
                    \(String(decoding: state.output.suffix(4096), as: UTF8.self))
                    """)
            }
            let diagnostic = try? await execute(
                "ps -u \"$(id -u)\" -o pid= -o ppid= -o tty= -o pgid= -o tpgid= -o comm=; "
                    + "find /tmp/termind-shell.* -name journal -exec cat {} \\; 2>/dev/null")
            if let diagnostic { print(diagnostic.stdout) }
            Issue.record("\(backendID.rawValue) \(managed ? "managed" : "manual") failed at \(stage): \(error)")
            await cleanup()
            throw error
        }
    }

    private func attach(
        _ channel: SSHPTYChannel, state: State, fixture: Fixture, backend: any RemoteSessionBackend,
        reference: RemoteSessionReference?, root: String, name: String
    ) async throws {
        await channel.configureStartup { _ in
            guard let reference else { return nil }
            let launch = try backend.launch(reference, created: false)
            return SSHPTYStartupPlan(command: launch.command, runtimeAttachment: launch.attachment)
        }
        try await connect(channel, fixture: fixture)
        if reference == nil {
            try await wait { state.context.status == .ordinary && state.context.active?.promptReady == true }
            await channel.write(Data((try nativeAttach(backend.id, root: root, name: name) + "\r").utf8))
        }
    }

    private func verifyPaneChange(
        _ backend: SessionPersistenceBackendID, channel: SSHPTYChannel, state: State,
        reference: RemoteSessionReference?, root: String, name: String, execute: RemoteSessionCommandExecutor
    ) async throws {
        if backend == .zmx { return }
        let first = try #require(state.context.active)
        let route: String
        let target: String
        if let reference, backend != .tmux {
            let identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: backend)
            route = try #require(RemoteMultiplexerRegistry.socketDialect(backend)).routing(identity)
            target = reference.session.name
        } else {
            route = try nativeEnvironment(backend, root: root)
            target = reference?.session.name ?? name
        }
        let command: String
        switch backend {
        case .tmux:
            command =
                "tmux split-window -P -F '#{pane_id}' -t \(try quote(target)) -c /opt"
                + (reference == nil ? " '/bin/bash --noprofile --norc'" : "")
        case .zellij:
            command = "zellij --session \(try quote(target)) action new-pane"
        case .herdr:
            command =
                "herdr --session \(try quote(target)) pane split \(try quote(first.identity.pane)) "
                + "--direction right --cwd /opt --focus"
        default: throw TerminalRuntimeError.unsupported
        }
        let created = try await execute(route + "\n" + command)
        try #require(created.exitCode == 0, "\(created.stderr)")
        let close: String
        if backend == .herdr {
            struct Response: Decodable {
                struct Result: Decodable {
                    struct Pane: Decodable {
                        let paneID: String
                        enum CodingKeys: String, CodingKey { case paneID = "pane_id" }
                    }
                    let pane: Pane
                }
                let result: Result
            }
            let pane = try JSONDecoder().decode(Response.self, from: Data(created.stdout.utf8)).result.pane.paneID
            try await wait { state.context.backend == .herdr && state.context.directory == nil }
            #expect(state.context.active == nil)
            close = "herdr --session \(try quote(target)) pane close \(try quote(pane))"
        } else {
            if backend == .zellij {
                try await wait {
                    state.context.active?.identity.pane != nil
                        && state.context.active?.identity.pane != first.identity.pane
                        && (reference == nil || state.context.active?.promptReady == true)
                }
                await channel.write(Data("cd /opt\r".utf8))
            }
            try await wait {
                state.context.directory == "/opt" && state.context.active?.identity.pane != first.identity.pane
            }
            if reference != nil {
                #expect(state.context.active?.directorySource == .shell)
            }
            let pane = try #require(state.context.active?.identity.pane)
            close =
                backend == .tmux
                ? "tmux kill-pane -t \(try quote(pane))"
                : "zellij --session \(try quote(target)) action close-pane --pane-id \(try quote(pane))"
        }
        let closed = try await execute(route + "\n" + close)
        try #require(closed.exitCode == 0, "\(closed.stderr)")
        try await wait { state.context.active?.identity == first.identity && state.context.directory == "/var" }
    }

    private func nativeEnvironment(_ backend: SessionPersistenceBackendID, root: String) throws -> String {
        switch backend {
        case .zellij: return "export ZELLIJ_SOCKET_DIR=\(try quote(root))"
        case .zmx: return "export ZMX_DIR=\(try quote(root))"
        case .herdr: return "export XDG_CONFIG_HOME=\(try quote(root))"
        default: return ""
        }
    }

    private func nativeCreate(
        _ backend: SessionPersistenceBackendID, root: String, name: String, directory: String
    ) throws -> String {
        let prefix =
            "mkdir -p \(try quote(root)); cd \(try quote(directory)) || exit 1\n"
            + (try nativeEnvironment(backend, root: root)) + "\n"
        switch backend {
        case .tmux:
            return prefix
                + "tmux new-session -d -s \(try quote(name)) -c \(try quote(directory)) '/bin/bash --noprofile --norc'"
        case .zellij:
            return prefix
                + "zellij --layout-string 'default_shell \"/bin/bash\"\nsession_serialization false\nlayout { pane; }' "
                + "attach --create-background \(try quote(name))"
        case .zmx:
            return prefix + "zmx attach \(try quote(name)) /bin/bash --noprofile --norc </dev/null >/dev/null"
        case .herdr:
            return prefix
                + "mkdir -p \(try quote(root + "/herdr"))\n"
                + "printf 'onboarding = false\\n' > \(try quote(root + "/herdr/config.toml"))\n"
                + "SHELL=/bin/bash HERDR_STARTUP_CWD=$PWD nohup herdr --session \(try quote(name)) server "
                + "</dev/null >\(try quote(root + "/" + name + ".log")) 2>&1 &\n"
                + "for attempt in $(seq 1 50); do [ -S \(try quote(root + "/herdr/sessions/" + name + "/herdr-client.sock")) ] "
                + "&& exit 0; sleep 0.1; done; exit 1"
        default: throw TerminalRuntimeError.unsupported
        }
    }

    private func nativeAttach(_ backend: SessionPersistenceBackendID, root: String, name: String) throws -> String {
        let prefix = try nativeEnvironment(backend, root: root)
        let command: String
        switch backend {
        case .tmux: command = "tmux attach-session -t \(try quote(name))"
        case .zellij: command = "zellij attach \(try quote(name))"
        case .zmx: command = "zmx attach \(try quote(name))"
        case .herdr: command = "herdr --session \(try quote(name)) client"
        default: throw TerminalRuntimeError.unsupported
        }
        return (prefix.isEmpty ? "" : prefix + "; ") + command
    }

    private func nativeStop(_ backend: SessionPersistenceBackendID, root: String, name: String) throws -> String {
        let prefix = try nativeEnvironment(backend, root: root) + "\n"
        switch backend {
        case .tmux: return prefix + "tmux kill-session -t \(try quote(name))"
        case .zellij: return prefix + "zellij kill-session \(try quote(name))"
        case .zmx: return prefix + "zmx kill \(try quote(name)) --force"
        case .herdr:
            return prefix
                + "herdr session stop \(try quote(name)) --json && herdr session delete \(try quote(name)) --json"
        default: throw TerminalRuntimeError.unsupported
        }
    }

    private func detachKeys(_ backend: SessionPersistenceBackendID) -> [UInt8] {
        switch backend {
        case .tmux: [0x02, 0x64]
        case .zellij: [0x0F, 0x64]
        case .zmx: [0x1C]
        case .herdr: [0x02, 0x71]
        default: []
        }
    }

    private func quote(_ value: String) throws -> String { try RemoteMultiplexerCommands.quote(value) }

    private func connect(_ channel: SSHPTYChannel, fixture: Fixture) async throws {
        try await channel.connect(using: fixture.request(), shellIntegrationEnabled: true, columns: 100, rows: 30)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw TerminalRuntimeError.invalidResponse
    }
}

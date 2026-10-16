import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
nonisolated struct NativeTerminalContextTests {
    private static func hex(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private static func client(_ backend: SessionPersistenceBackendID) -> RemoteTerminalProcessProbe.Client {
        .init(
            backend: backend, process: "42", started: "Fri Oct 16 12:00:00 2026",
            endpoint: backend == .herdr ? "/tmp/herdr/herdr-client.sock" : "/tmp/\(backend.rawValue)/work")
    }

    private static func frame(
        _ backend: SessionPersistenceBackendID, native: String, focus: String = "", directory: String = ""
    ) -> String {
        let version = backend == .zellij ? "0.45.1" : backend == .zmx ? "0.8.1" : "0.9.5"
        return """
            V|\(hex("\(backend.rawValue) \(version)"))
            I|1:2:3
            N|\(hex(native))
            F|\(hex(focus))
            D|\(hex(directory))
            DONE

            """
    }

    @Test func linuxSocketPeersBindTheActualSessionRatherThanOtherClientsOrArgv() {
        let sockets = """
            u_str ESTAB 0 0 * 100 * 200 users:(("zmx",pid=42,fd=3))
            u_str ESTAB 0 0 /tmp/zmx/work 200 * 100 users:(("zmx",pid=50,fd=4))
            u_str ESTAB 0 0 * 300 * 400 users:(("zmx",pid=142,fd=3))
            u_str ESTAB 0 0 /tmp/zmx/other 400 * 300 users:(("zmx",pid=60,fd=4))
            """
        #expect(RemoteTerminalProcessProbe.linuxEndpoint(sockets, process: "42") == "/tmp/zmx/work")
        #expect(RemoteTerminalProcessProbe.linuxEndpoint(sockets, process: "2") == nil)
        #expect(
            RemoteTerminalProcessProbe.linuxEndpoint(
                sockets.replacingOccurrences(of: "200 * 100", with: "200 * 999"), process: "42") == nil)
        #expect(
            RemoteTerminalProcessProbe.linuxEndpoint(
                sockets.replacingOccurrences(of: "pid=142,", with: "pid=42,"), process: "42") == nil)
    }

    @Test func darwinUsesTheSocketDeviceAddressNotTheMissingBlockDeviceField() {
        let sockets = """
            p50
            f3
            d0x111
            n/tmp/zmx/work
            f4
            d0x222
            n/tmp/zmx/work
            p42
            f3
            d0x333
            n->0x222
            """
        #expect(RemoteTerminalProcessProbe.darwinEndpoint(sockets, process: "42") == "/tmp/zmx/work")
        #expect(
            RemoteTerminalProcessProbe.darwinEndpoint(
                sockets.replacingOccurrences(of: "->0x222", with: "->0x999"), process: "42") == nil)
    }

    @Test func socketDiagnosticEvidenceRequiresABoundedAbsoluteEndpoint() throws {
        let client = Self.client(.zellij)
        func frame(_ path: String) -> String {
            "M|zellij|42|\(Self.hex(client.started))\nP|\(Self.hex(path))\nDONE\n"
        }
        #expect(try RemoteTerminalProcessProbe.parse(frame(client.endpoint!)) == client)
        for path in ["", "relative/session", "/tmp/../session", "/tmp/\0session"] {
            #expect(try RemoteTerminalProcessProbe.parse(frame(path))?.endpoint == nil)
        }
        #expect(throws: RemoteSessionFailure.invalidResponse) {
            try RemoteTerminalProcessProbe.parse(frame("/" + String(repeating: "x", count: 262144)))
        }
        #expect(throws: TerminalRuntimeError.invalidResponse) {
            try RemoteTerminalProcessProbe.parse(String(frame(client.endpoint!).dropLast()))
        }
    }

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func missingEndpointDoesNotBecomeAnOrdinaryShell(backend: SessionPersistenceBackendID) async throws {
        let client = Self.client(backend)
        let response = "M|\(backend.rawValue)|42|\(Self.hex(client.started))\nS|\nDONE\n"
        let runtime = RemoteMultiplexerRuntimeAdapter { command in
            .init(
                stdout: command.contains("ss -xnpH") ? response : "tmux 3.3a\nNONE\n",
                stderr: "", exitCode: 0)
        }
        let update = try await runtime.inspect(terminal: "/dev/pts/1")
        #expect(update.status == .multiplexer)
        #expect(update.backend == backend)
        #expect(update.issue == .clientUnbound)
        #expect(update.active == nil)
    }

    @Test func unavailableManagedHelperStillFallsBackToTheBoundNativePane() async throws {
        let client = Self.client(.zellij)
        let token = UUID()
        let identity = RemoteMultiplexerIdentity(
            kind: .zellij, root: "/tmp/zellij", socket: try #require(client.endpoint), fingerprint: "1:2:3",
            process: nil, created: nil, owner: token, helper: "/tmp/termind-shell.testing", isolated: true)
        let reference = RemoteSessionReference(
            backend: .zellij,
            session: .init(id: "managed:work", name: "work", identity: try JSONEncoder().encode(identity)),
            hostID: UUID(), endpoint: "fixture", username: "user", ownershipToken: token)
        let runtime = RemoteMultiplexerRuntimeAdapter(attachment: reference) { command in
            if command.contains("ss -xnpH") {
                return .init(
                    stdout: "M|zellij|42|\(Self.hex(client.started))\nP|\(Self.hex(client.endpoint!))\nDONE\n",
                    stderr: "", exitCode: 0)
            }
            if command.contains("action list-panes --json") {
                return .init(
                    stdout: Self.frame(
                        .zellij, native: #"[{"id":1,"is_plugin":false,"pane_cwd":"/native","pane_command":"bash"}]"#,
                        focus: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_1 bash"),
                    stderr: "", exitCode: 0)
            }
            return .init(stdout: "", stderr: "", exitCode: 79)
        }
        let update = try await runtime.inspect(terminal: "/dev/pts/1")
        #expect(update.active?.pane == "1")
        #expect(update.contexts.first?.directory == "/native")
        #expect(update.contexts.first?.directorySource == .nativePane)
        #expect(update.contexts.first?.capabilities.isEmpty == true)
    }

    @Test @MainActor func detectedMultiplexerNeverRetainsTheOuterDirectoryOnFailure() {
        let model = TerminalContextCoordinator()
        let shell = TerminalShellContext(
            identity: .init(backend: "shell", server: "s", session: "s", pane: "shell", shellInstance: "outer"),
            shell: "bash", directory: "/outer", home: nil, promptReady: false, sequence: 1, capabilities: [])
        let current = TerminalRuntimeUpdate(status: .ordinary, active: shell.identity, contexts: [shell])
        model.receive(current, generation: model.generation)
        let failed = TerminalRuntimeUpdate(status: .unavailable, backend: .zellij, issue: .clientUnbound)
        let reconciled = RemoteTerminalContextFilter.reconcileObservation(failed, current: current)
        model.receive(reconciled, generation: model.generation)
        #expect(model.directory == nil)
        #expect(model.backend == .zellij)
        #expect(model.issue == .clientUnbound)
        #expect(model.ticket(requiring: .directory) == nil)
    }

    @Test @MainActor func zellijNativeDirectoryDoesNotGrantShellOrInputPermissions() throws {
        let native = """
            [{"id":1,"is_plugin":false,"pane_cwd":"/tmp/a|b","pane_command":"bash"},
             {"id":2,"is_plugin":false,"pane_cwd":"/other","pane_command":"zsh"}]
            """
        let update = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(.zellij, native: native, focus: "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n7 terminal_1 bash"),
            client: Self.client(.zellij))
        let model = TerminalContextCoordinator()
        model.receive(update, generation: model.generation)
        #expect(model.directory == "/tmp/a|b")
        #expect(model.active?.directorySource == .nativePane)
        #expect(model.active?.historySource == nil)
        #expect(model.active?.promptReady == false)
        for capability in [
            TerminalContextCapabilities.directory, .commandLifecycle, .readDraft, .replaceDraft,
        ] {
            #expect(model.ticket(requiring: capability) == nil)
        }
    }

    @Test func zellijOnlyUsesUnanimousFocusWithoutATtyToNativeClientIDMapping() {
        let first = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_2 bash"
        #expect(RemoteNativeMultiplexerRuntime.zellijPane(first + "\n2 terminal_2 zsh") == "2")
        #expect(RemoteNativeMultiplexerRuntime.zellijPane(first + "\n2 terminal_3 zsh") == nil)
        #expect(RemoteNativeMultiplexerRuntime.zellijPane(first + "\n2 plugin_3 menu") == nil)
        #expect(RemoteNativeMultiplexerRuntime.zellijPane(first + "\n1 terminal_2 bash") == nil)
    }

    @Test func zmxReadsTheBoundShellDirectoryNotTheCachedListDirectory() throws {
        let native = """
              name=other\tpid=222\tclients=1\tcreated=123\tcwd=/other
              name=work\tpid=123\tclients=2\tcreated=456\tcwd=/stale
            """
        let update = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(.zmx, native: native, focus: "123:process-start", directory: "/actual"),
            client: Self.client(.zmx))
        #expect(update.contexts.first?.directory == "/actual")
        #expect(update.contexts.first?.directorySource == .process)
        #expect(update.contexts.first?.capabilities.isEmpty == true)
        let replaced = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(.zmx, native: native, focus: "124:process-start", directory: "/wrong"),
            client: Self.client(.zmx))
        #expect(replaced.active == nil)
    }

    @Test func herdrDoesNotSubstituteGlobalFocusOrSavedWorkspaceCwd() throws {
        let client = Self.client(.herdr)
        let cached = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(.herdr, native: #"{"result":{"panes":[{"pane_id":"w1:p1","cwd":"/saved"}]}}"#),
            client: client)
        #expect(cached.active == nil)
        #expect(cached.issue == .directoryUnavailable)
        let live = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(
                .herdr,
                native: #"{"result":{"panes":[{"pane_id":"w1:p1","cwd":"/saved","foreground_cwd":"/actual"}]}}"#),
            client: client)
        #expect(live.contexts.first?.directory == "/actual")
        let ambiguous = try RemoteNativeMultiplexerRuntime.parse(
            Self.frame(
                .herdr,
                native:
                    #"{"result":{"panes":[{"pane_id":"w1:p1","foreground_cwd":"/a","focused":true},{"pane_id":"w2:p1","foreground_cwd":"/b"}]}}"#
            ),
            client: client)
        #expect(ambiguous.active == nil)
        #expect(ambiguous.issue == .paneAmbiguous)
    }

    @Test func tmuxUnintegratedPaneGetsOnlyANativeDisplayDirectory() throws {
        let frame = """
            tmux 3.3a
            C|/dev/pts/1|555|100|777|$0|99|%2||root
            P|%2|456|0|0|bash
            D|%2|\(Self.hex("/native"))|\(Self.hex("bash"))
            DONE

            """
        let update = try RemoteTmuxRuntimeDialect.parse(frame, terminal: "/dev/pts/1")
        #expect(update.contexts.first?.directory == "/native")
        #expect(update.contexts.first?.directorySource == .nativePane)
        #expect(update.contexts.first?.capabilities.isEmpty == true)
        let nested = try RemoteTmuxRuntimeDialect.parse(
            frame.replacingOccurrences(of: Self.hex("bash") + "\n", with: Self.hex("zellij") + "\n"),
            terminal: "/dev/pts/1")
        #expect(nested.active == nil)
        #expect(nested.issue == .nestedMultiplexer)
    }

    @Test func nativeResponsesRejectTruncationAndNonPaths() throws {
        let text = Self.frame(.zmx, native: "name=work\tpid=123\tclients=1\tcreated=456", focus: "123:start")
        #expect(throws: (any Error).self) {
            try RemoteNativeMultiplexerRuntime.parse(String(text.dropLast()), client: Self.client(.zmx))
        }
        #expect(try RemoteNativeMultiplexerRuntime.parse(text, client: Self.client(.zmx)).active == nil)
        #expect(throws: (any Error).self) {
            try RemoteTerminalProcessProbe.parse("M|zmx|42|00\nS|\nDONE\n")
        }
    }
}

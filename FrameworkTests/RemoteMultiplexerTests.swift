import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
nonisolated struct RemoteMultiplexerTests {
    private static let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let kinds: [RemoteMultiplexerKind] = [.tmux, .zellij, .zmx, .herdr]

    @Test(arguments: kinds)
    func registryAndVersionProbeUseTheSameService(kind: RemoteMultiplexerKind) async throws {
        let versions: [RemoteMultiplexerKind: String] = [
            .tmux: "tmux 3.3a\n", .zellij: "zellij 0.44.3\n",
            .zmx: "zmx\t\t0.7.0\nghostty_vt\t1.2.3\nsocket_dir\t/tmp/zmx\nlog_dir\t/tmp\n",
            .herdr: "herdr 0.7.5\n",
        ]
        let recorder = Recorder([.init(stdout: versions[kind]!, stderr: "", exitCode: 0)])
        let backend = try RemoteSessionBackendRegistry.live.backend(
            kind.id, execute: { try await recorder.execute($0) })
        #expect(backend is RemoteMultiplexerService)
        #expect(try await backend.probe().shellIntegration)
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("command -v \(kind.rawValue)"))
        #expect(!command.contains("new-session"))
    }

    @Test(arguments: [
        ("zellij", "0.44.2", false), ("zellij", "0.44.3", true), ("zellij", "1.0.0", true),
        ("zmx", "0.6.9", false), ("zmx", "0.7.0", true),
        ("herdr", "0.7.4", false), ("herdr", "0.7.5", true), ("herdr", "0.7.99", true),
        ("herdr", "0.8.0", false), ("herdr", "0.8.1", false), ("herdr", "0.8.2", true),
    ])
    func versionBoundaries(value: (String, String, Bool)) throws {
        let kind = try #require(RemoteMultiplexerKind(rawValue: value.0))
        if value.2 {
            try kind.validateVersion("\(value.0) \(value.1)\n")
        } else {
            #expect(throws: RemoteSessionFailure.unsupported) {
                try kind.validateVersion("\(value.0) \(value.1)\n")
            }
        }
        #expect(throws: (any Error).self) { try kind.validateVersion("\(value.0) 0.99\n") }
        #expect(throws: (any Error).self) { try kind.validateVersion("\(value.0) 0.99.0-dev\n") }
    }

    @Test(arguments: kinds)
    func failuresAndTruncationNeverEnableABackend(kind: RemoteMultiplexerKind) async {
        for (response, expected) in [
            (RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 77), RemoteSessionFailure.missing),
            (.init(stdout: "", stderr: "", exitCode: 79), .ownershipMismatch),
            (.init(stdout: "", stderr: "", exitCode: 81), .startupUnavailable),
            (.init(stdout: "partial", stderr: "", exitCode: 0, truncated: true), .invalidResponse),
            (.init(stdout: "not a version", stderr: "", exitCode: 0), .invalidResponse),
        ] {
            let backend = RemoteMultiplexerService(backend: kind.id) { _ in response }
            await #expect(throws: expected) { try await backend.probe() }
        }
    }

    @Test func nativeListingsAreStrictAndDoNotInferOwnershipFromLabelsOrNames() throws {
        let zmx = try RemoteZmxCommands.parseList(
            "ROOT|\(Self.hex("/tmp/zmx"))\nname=termind-external\tpid=123\tclients=2\tcreated=456\tmanaged=true\nEND\n")
        #expect(zmx.first?.clients == 2)
        #expect(zmx.first?.process == "123")
        let zellij = try RemoteZellijCommands.parseList(Self.list(.zellij))
        #expect(zellij.count == 1)
        #expect(zellij.first?.isolated == true)
        let herdr = try RemoteHerdrCommands.parseList(Self.list(.herdr))
        #expect(herdr.map(\.name) == [Self.name])
        for value in [
            "name=test\tpid=123\tclients=1", "name=test\tpid=123\tclients=-1\tcreated=456",
            "name=test\tpid=123\tpid=456\tclients=1\tcreated=456", "{\"sessions\":[]}",
            "name=../test\tpid=123\tclients=1\tcreated=456", "name=test\terr=Timeout",
        ] {
            #expect(throws: (any Error).self) {
                try RemoteZmxCommands.parseList("ROOT|\(Self.hex("/tmp/zmx"))\n\(value)\nEND\n")
            }
        }
        #expect(throws: (any Error).self) { try RemoteZmxCommands.parseList(String(Self.list(.zmx).dropLast(4))) }
        #expect(throws: (any Error).self) { try RemoteZellijCommands.parseList(String(Self.list(.zellij).dropLast(4))) }
        #expect(throws: (any Error).self) { try RemoteHerdrCommands.parseList(String(Self.list(.herdr).dropLast())) }
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr])
    func recoveryRejectsReplacedInstancesAndNeverAcquiresManualOwnership(kind: RemoteMultiplexerKind) throws {
        let reference = try Self.reference(kind)
        let backend = RemoteMultiplexerService(backend: kind.id) { _ in throw CancellationError() }
        #expect(backend.matches(reference, session: reference.session))
        var identity = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: kind)
        identity = .init(
            kind: kind, root: identity.root, socket: identity.socket, fingerprint: "1:2:999",
            process: identity.process, created: identity.created, owner: Self.token,
            helper: identity.helper, isolated: identity.isolated, directoryFingerprint: identity.directoryFingerprint,
            daemonProcess: identity.daemonProcess, daemonStarted: identity.daemonStarted)
        let replacement = RemoteSessionDescriptor(
            id: reference.session.id, name: reference.session.name, identity: try JSONEncoder().encode(identity))
        #expect(!backend.matches(reference, session: replacement))
        let manual = RemoteSessionReference(
            backend: kind.id, session: reference.session, hostID: UUID(),
            endpoint: "server:22", username: "user", ownershipToken: nil)
        #expect(try !backend.launch(manual, created: false).attachment.isManaged)
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr])
    func identityRoutingAndOwnershipAreRecheckedBeforeClose(kind: RemoteMultiplexerKind) async throws {
        let recorder = Recorder([.init(stdout: "TERMIND_ENDED\n", stderr: "", exitCode: 0)])
        let backend = RemoteMultiplexerService(backend: kind.id, execute: { try await recorder.execute($0) })
        let reference = try Self.reference(kind)
        try await backend.terminate(reference)
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("fingerprint"))
        #expect(command.contains(Self.token.uuidString))
        #expect(command.contains("private_state"))
        if kind == .zmx {
            #expect(command.contains("termind_owner"))
            #expect(command.contains("123:456"))
            #expect(command.contains("kill '\(Self.name)' --force"))
        }
        if kind == .herdr {
            #expect(command.contains("XDG_CONFIG_HOME='/tmp/test-config'"))
            #expect(command.contains("directory_fingerprint"))
            #expect(command.contains("session stop"))
            #expect(command.contains("session delete"))
        }
        let manual = RemoteSessionReference(
            backend: kind.id, session: reference.session, hostID: UUID(),
            endpoint: "", username: "", ownershipToken: nil)
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) { try await backend.terminate(manual) }
        #expect(await recorder.commands.count == 1)
    }

    @Test func zmxDaemonReplacementDoesNotMatchEvenIfTheSocketFingerprintIsUnchanged() throws {
        let reference = try Self.reference(.zmx)
        let original = try RemoteMultiplexerIdentity.decode(reference.session.identity, kind: .zmx)
        let service = RemoteMultiplexerService(backend: .zmx) { _ in throw CancellationError() }
        for (pid, created, owner) in [
            ("124", "456", Self.token), ("123", "457", Self.token), ("123", "456", UUID()),
        ] {
            let changed = RemoteMultiplexerIdentity(
                kind: .zmx, root: original.root, socket: original.socket, fingerprint: original.fingerprint,
                process: pid, created: created, owner: owner, helper: original.helper, isolated: false,
                daemonProcess: original.daemonProcess, daemonStarted: original.daemonStarted)
            let session = RemoteSessionDescriptor(
                id: reference.session.id, name: reference.session.name, identity: try JSONEncoder().encode(changed))
            #expect(!service.matches(reference, session: session))
        }
        var replacedDaemon = original
        replacedDaemon.daemonStarted = "Fri Oct 16 10:00:01 2026"
        let session = RemoteSessionDescriptor(
            id: reference.session.id, name: reference.session.name, identity: try JSONEncoder().encode(replacedDaemon))
        #expect(!service.matches(reference, session: session))
    }

    @Test func herdrDefaultAndForeignOwnershipNeverReachStopOrDelete() async throws {
        let recorder = Recorder([])
        let service = RemoteMultiplexerService(backend: .herdr, execute: { try await recorder.execute($0) })
        let identity = RemoteMultiplexerIdentity(
            kind: .herdr, root: "/tmp/config/herdr", socket: "/tmp/config/herdr/herdr.sock",
            fingerprint: "1:2:3", process: nil, created: nil, owner: Self.token, helper: nil,
            isolated: false, directoryFingerprint: "1:2")
        let session = RemoteSessionDescriptor(
            id: "user:default", name: "default", identity: try JSONEncoder().encode(identity))
        let reference = RemoteSessionReference(
            backend: .herdr, session: session, hostID: UUID(), endpoint: "", username: "",
            ownershipToken: Self.token)
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) { try await service.terminate(reference) }
        let owned = try Self.reference(.herdr)
        let foreign = RemoteSessionReference(
            backend: .herdr, session: owned.session, hostID: UUID(), endpoint: "", username: "",
            ownershipToken: UUID())
        await #expect(throws: RemoteSessionFailure.ownershipMismatch) { try await service.terminate(foreign) }
        #expect(await recorder.commands.isEmpty)
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr])
    func closeFailureAndIncompleteOutputAreNotReportedAsSuccess(kind: RemoteMultiplexerKind) async throws {
        for response in [
            RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 79),
            .init(stdout: "TERMIND_ENDED", stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_ENDED\n", stderr: "", exitCode: 0, truncated: true),
        ] {
            let service = RemoteMultiplexerService(backend: kind.id) { _ in response }
            await #expect(throws: (any Error).self) { try await service.terminate(Self.reference(kind)) }
        }
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr])
    func confirmedCreateRetriesNeverReplayStartupOrCreateAnotherShell(kind: RemoteMultiplexerKind) async throws {
        let recorder = Recorder([
            .init(stdout: Self.list(kind), stderr: "", exitCode: 0),
            .init(stdout: Self.metadata(kind), stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_CREATED\n", stderr: "", exitCode: 0),
        ])
        let service = RemoteMultiplexerService(backend: kind.id, execute: { try await recorder.execute($0) })
        let session = try await service.create(
            token: Self.token, startupCommand: "echo NEVER_REPLAY", shellIntegration: true)
        #expect(session.name == Self.name)
        let completion = try #require(await recorder.commands.last)
        #expect(completion.contains("/started"))
        #expect(!completion.contains("NEVER_REPLAY"))
        #expect(!completion.contains("attach --create"))
        #expect(!completion.contains(" server "))
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr])
    func freshCreateInstallsWrapperAndConfirmsTheOwnedIncarnation(kind: RemoteMultiplexerKind) async throws {
        let recorder = Recorder([
            .init(stdout: Self.list(kind, empty: true), stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_CREATED\n", stderr: "", exitCode: 0),
            .init(stdout: Self.list(kind), stderr: "", exitCode: 0),
            .init(stdout: Self.metadata(kind), stderr: "", exitCode: 0),
        ])
        let service = RemoteMultiplexerService(backend: kind.id, execute: { try await recorder.execute($0) })
        _ = try await service.create(
            token: Self.token, startupCommand: "cd /tmp; export FROM_SNIPPET=yes", shellIntegration: true)
        let create = await recorder.commands[1]
        #expect(create.contains("first-claimed"))
        #expect(create.contains("cd /tmp; export FROM_SNIPPET=yes"))
        #expect(create.contains("TERMIND_CREATED"))
        switch kind {
        case .zellij:
            #expect(create.contains("--session-serialization false"))
            #expect(create.contains("--layout-string 'layout { pane; }'"))
        case .zmx:
            #expect(create.contains("termind_owner=\(Self.token.uuidString)"))
            #expect(create.contains("</dev/null"))
        case .herdr:
            #expect(create.contains("SHELL=\"$helper/shell\""))
            #expect(create.contains("HERDR_STARTUP_CWD"))
            #expect(!create.contains("config.toml"))
        case .tmux: break
        }
    }

    @Test func attachingCannotImplicitlyStartAnInteractiveReplacement() throws {
        let zmx = try RemoteMultiplexerService(backend: .zmx) { _ in throw CancellationError() }
            .launch(Self.reference(.zmx), created: false).command
        #expect(zmx.contains("attach '\(Self.name)' /bin/sh -c 'exit 79'"))
        #expect(!zmx.contains("default-shell"))
        let herdr = try RemoteMultiplexerService(backend: .herdr) { _ in throw CancellationError() }
            .launch(Self.reference(.herdr), created: false).command
        #expect(herdr.contains("--session '\(Self.name)' client"))
        #expect(!herdr.contains("session attach"))
        #expect(!herdr.contains(" server"))
    }

    @Test(arguments: [RemoteMultiplexerKind.zellij, .zmx, .herdr]) @MainActor
    func runtimeRequiresUnambiguousClientFocusAndKeepsJournalsBackendScoped(kind: RemoteMultiplexerKind) throws {
        let reference = try Self.reference(kind)
        let pane = kind == .zmx ? "shell" : "1"
        let record = """
            M2|\(Self.token.uuidString)|\(pane)|ctx.abc123|bash|%2Fhome%2Fuser|321|%2Ftmp%2Fhistory|\(kind.rawValue)
            R1|2|1|%2Ftmp
            E1|1|directory|%2Ftmp|
            E1|2|prompt||
            """
        let native: String
        let focus: String
        switch kind {
        case .zellij:
            native = Self.name
            focus = "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\n1 terminal_1 bash"
        case .zmx:
            native = "name=\(Self.name)\tpid=123\tclients=1\tcreated=456"
            focus = "shell"
        case .herdr:
            native = Self.list(.herdr)
            focus = #"{"result":{"panes":[{"pane_id":"1"}]}}"#
        case .tmux: return
        }
        func frame(_ native: String, _ focus: String) -> String {
            "C|987\nN|\(Self.hex(native))\nA|\(Self.hex(focus))\nBEGIN|1\n\(record)\nEND\nDONE\n"
        }
        let update = try RemoteSocketMultiplexerRuntime.parse(frame(native, focus), reference: reference)
        if kind == .herdr {
            #expect(update.active == nil)
        } else {
            #expect(update.active?.pane == pane)
            #expect(update.contexts.first?.capabilities.contains(.replaceDraft) == true)
            let ambiguousNative =
                kind == .zmx ? native.replacingOccurrences(of: "clients=1", with: "clients=2") : native
            let ambiguousFocus = kind == .zellij ? focus + "\n2 terminal_2 bash" : focus
            let ambiguous = try RemoteSocketMultiplexerRuntime.parse(
                frame(ambiguousNative, ambiguousFocus), reference: reference)
            #expect(ambiguous.active == nil)
            #expect(ambiguous.contexts.allSatisfy { !$0.capabilities.contains(.replaceDraft) })
        }
        let running = try RemoteSocketMultiplexerRuntime.parse(
            frame(native, focus)
                .replacingOccurrences(of: "BEGIN|1", with: "BEGIN|0")
                .replacingOccurrences(of: "R1|2|1|", with: "R1|3|0|")
                .replacingOccurrences(of: "\nEND\n", with: "\nE1|3|start|sleep%2010|\nEND\n"),
            reference: reference)
        let coordinator = TerminalContextCoordinator()
        coordinator.receive(update, generation: coordinator.generation)
        coordinator.receive(running, generation: coordinator.generation)
        #expect(running.contexts.first?.directory == "/tmp")
        // Herdr still cannot bind a client to its active pane; never substitute global focus.
        #expect(coordinator.directory == (kind == .herdr ? nil : "/tmp"))
        #expect(coordinator.ticket(requiring: .directory) == nil)
        #expect(coordinator.ticket(requiring: .readDraft) == nil)
        #expect(coordinator.ticket(requiring: .replaceDraft) == nil)
        #expect(throws: (any Error).self) {
            try RemoteSocketMultiplexerRuntime.parse(String(frame(native, focus).dropLast(6)), reference: reference)
        }
        #expect(throws: (any Error).self) {
            try RemoteSocketMultiplexerRuntime.parse(
                frame(native, focus).replacingOccurrences(of: "|\(kind.rawValue)\n", with: "|foreign\n"),
                reference: reference)
        }
    }

    @Test func quotingCannotEscapeIntoShellSyntax() throws {
        #expect(try RemoteMultiplexerCommands.quote("a'b\n$(touch /tmp/no)") == "'a'\\''b\n$(touch /tmp/no)'")
        #expect(throws: RemoteSessionFailure.invalidResponse) { try RemoteMultiplexerCommands.quote("bad\0value") }
        #expect(!RemoteMultiplexerCommands.validName("test*"))
        #expect(!RemoteMultiplexerCommands.validPath("/tmp/../etc"))
    }

    private static var name: String { RemoteMultiplexerCommands.managedName(token) }
    private static func hex(_ value: String) -> String { value.utf8.map { String(format: "%02x", $0) }.joined() }
    private static func root(_ kind: RemoteMultiplexerKind) -> String {
        kind == .herdr ? "/tmp/test-config/herdr/sessions/\(name)" : "/tmp/\(kind.rawValue)"
    }
    private static func socket(_ kind: RemoteMultiplexerKind) -> String {
        root(kind) + (kind == .herdr ? "/herdr.sock" : "/\(name)")
    }
    private static func list(_ kind: RemoteMultiplexerKind, empty: Bool = false) -> String {
        switch kind {
        case .zellij:
            return "ROOT|user|\(hex("/tmp/user-zellij"))\nEND\nROOT|managed|\(hex(root(kind)))\n"
                + (empty ? "" : "\(name)\n") + "END\n"
        case .zmx:
            return "ROOT|\(hex(root(kind)))\n"
                + (empty ? "" : "name=\(name)\tpid=123\tclients=1\tcreated=456\n") + "END\n"
        case .herdr:
            return empty
                ? #"{"sessions":[]}"#
                : """
                {"sessions":[{"name":"\(name)","running":true,"socket_path":"\(socket(kind))","session_dir":"\(root(kind))"}]}
                """
        case .tmux: return "TERMIND_TMUX_1\n"
        }
    }
    private static func metadata(_ kind: RemoteMultiplexerKind) -> String {
        "F|0|\(hex(socket(kind)))|1:2:3|\(token.uuidString)|/tmp/termind-shell.testing|\(kind == .herdr ? "1:2" : "-")"
            + (kind == .zmx ? "|122|\(hex("Fri Oct 16 10:00:00 2026"))\n" : "|-|-\n")
    }
    private static func reference(_ kind: RemoteMultiplexerKind) throws -> RemoteSessionReference {
        let identity = RemoteMultiplexerIdentity(
            kind: kind, root: root(kind), socket: socket(kind), fingerprint: "1:2:3",
            process: kind == .zmx ? "123" : nil, created: kind == .zmx ? "456" : nil,
            owner: token, helper: "/tmp/termind-shell.testing", isolated: kind == .zellij,
            directoryFingerprint: kind == .herdr ? "1:2" : nil,
            daemonProcess: kind == .zmx ? "122" : nil,
            daemonStarted: kind == .zmx ? "Fri Oct 16 10:00:00 2026" : nil)
        return .init(
            backend: kind.id,
            session: .init(
                id: (kind == .zellij ? "managed:" : "user:") + name, name: name,
                identity: try JSONEncoder().encode(identity)),
            hostID: UUID(), endpoint: "server:22", username: "user", ownershipToken: token)
    }

    private actor Recorder {
        var responses: [RemoteSessionCommandResult]
        var commands: [String] = []
        init(_ responses: [RemoteSessionCommandResult]) { self.responses = responses }
        func execute(_ command: String) throws -> RemoteSessionCommandResult {
            commands.append(command)
            guard !responses.isEmpty else { throw RemoteSessionFailure.invalidResponse }
            return responses.removeFirst()
        }
    }
}

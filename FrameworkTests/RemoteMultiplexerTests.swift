import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
nonisolated struct RemoteMultiplexerTests {
    @Test func ordinaryStartupFallbackIsBoundedOneShotAndGenerationScoped() {
        let generation = UUID()
        var unsupportedShell = RemoteShellStartupReadiness(generation: generation, now: 100)
        unsupportedShell.receive(.init(status: .unknown))
        let beforeDeadline = unsupportedShell.poll(generation: generation, now: 3_000_000_099)
        let atDeadline = unsupportedShell.poll(generation: generation, now: 3_000_000_100)
        let afterCompletion = unsupportedShell.poll(generation: generation, now: 4_000_000_000)
        #expect(!beforeDeadline)
        #expect(atDeadline)
        #expect(!afterCompletion)
        var replaced = RemoteShellStartupReadiness(generation: generation, now: 100)
        let replacement = replaced.poll(generation: UUID(), now: 4_000_000_000)
        let afterReplacement = replaced.poll(generation: generation, now: 4_000_000_000)
        #expect(!replacement)
        #expect(!afterReplacement)
        for status in [TerminalRuntimeUpdate.Status.ordinary, .multiplexer] {
            var integrated = RemoteShellStartupReadiness(generation: generation, now: 100)
            integrated.receive(.init(status: status))
            let afterIntegration = integrated.poll(generation: generation, now: 4_000_000_000)
            #expect(!afterIntegration)
        }
    }

    private static let token = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let kinds = SessionPersistenceBackendID.supported

    @Test func registeredDialectsCoverTheAdvertisedBackendsWithoutAliases() {
        let registered = RemoteMultiplexerRegistry.dialects.map(\.id)
        #expect(Set(registered) == Set(SessionPersistenceBackendID.supported))
        #expect(Set(registered).count == registered.count)
    }

    @Test func unknownBackendNeverExecutesSessionOrRuntimeCommands() async throws {
        let id = SessionPersistenceBackendID(rawValue: "future")
        let recorder = Recorder([])
        let execute: RemoteSessionCommandExecutor = { try await recorder.execute($0) }
        #expect(throws: RemoteSessionFailure.unsupported) {
            try RemoteSessionBackendRegistry.live.backend(id, execute: execute)
        }
        let service = RemoteMultiplexerService(backend: id, execute: execute)
        await #expect(throws: RemoteSessionFailure.unsupported) { try await service.probe() }
        await #expect(throws: RemoteSessionFailure.unsupported) { try await service.sessions() }
        var reference = try Self.reference(.zellij)
        reference.backend = id
        let runtime = RemoteMultiplexerRuntimeAdapter(attachment: reference, execute: execute)
        await #expect(throws: TerminalRuntimeError.unsupported) { try await runtime.inspect(terminal: "/dev/pts/1") }
        #expect(throws: TerminalRuntimeError.unsupported) { try RemoteMultiplexerRuntimeAdapter.helper(for: reference) }
        #expect(await recorder.commands.isEmpty)
    }

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func legacyStringIdentityStillValidatesAndLaunchesWithoutChangingItsJSON(kind: SessionPersistenceBackendID)
        throws
    {
        let root = kind == .herdr ? "/tmp/config/herdr/sessions/existing" : "/tmp/\(kind.rawValue)"
        let socket = root + (kind == .herdr ? "/herdr.sock" : "/existing")
        let native =
            kind == .zmx
            ? #","process":"123","created":"456","daemonProcess":"122","daemonStarted":"Fri Oct 16 10:00:00 2026""#
            : ""
        let directory = kind == .herdr ? #","directoryFingerprint":"1:2""# : ""
        let json = """
            {"version":1,"kind":"\(kind.rawValue)","root":"\(root)","socket":"\(socket)","fingerprint":"1:2:3",\
            "isolated":\(kind == .zellij ? "true" : "false")\(native)\(directory)}
            """
        let identity = try RemoteMultiplexerIdentity.decode(Data(json.utf8), kind: kind)
        let encoded = try JSONEncoder().encode(identity)
        let original = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        let roundTrip = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
        #expect(original == roundTrip)
        let reference = RemoteSessionReference(
            backend: kind,
            session: .init(
                id: (kind == .zellij ? "managed:" : "user:") + "existing", name: "existing",
                identity: Data(json.utf8)),
            hostID: UUID(), endpoint: "server:22", username: "user", ownershipToken: nil)
        let backend = try RemoteSessionBackendRegistry.live.backend(kind) { _ in throw CancellationError() }
        try backend.validate(reference)
        #expect(backend.matches(reference, session: reference.session))
        let launch = try backend.launch(reference, created: false)
        #expect(!launch.attachment.isManaged)
        #expect(launch.command.contains("fingerprint"))
        #expect(launch.command.contains("'existing'"))
        let wrongKind: SessionPersistenceBackendID = kind == .zmx ? .herdr : .zmx
        #expect(throws: RemoteSessionFailure.unsupported) {
            try RemoteMultiplexerIdentity.decode(Data(json.utf8), kind: wrongKind)
        }
        #expect(throws: RemoteSessionFailure.invalidResponse) {
            try RemoteMultiplexerIdentity.decode(
                Data(json.replacingOccurrences(of: "\"kind\":\"\(kind.rawValue)\"", with: "\"kind\":\"future\"").utf8),
                kind: kind)
        }
    }

    @Test(arguments: [
        ("tmux", "%1", "TMUX_PANE"), ("zellij", "1", "ZELLIJ_PANE_ID"),
        ("zmx", "shell", ""), ("herdr", "pane:1", "HERDR_PANE_ID"),
    ])
    func registeredPanePolicyDrivesJournalInstallationAndParsing(value: (String, String, String)) throws {
        let installation = RemoteShellContextJournal.initialization(
            shell: "bash", token: Self.token.uuidString, backend: value.0)
        if !value.2.isEmpty {
            #expect(installation.contains("${\(value.2):-shell}"))
        } else {
            #expect(!installation.contains("TMUX_PANE"))
        }
        let metadata = """
            M2|\(Self.token.uuidString)|\(value.1)|ctx.abc123|bash|%2Fhome|321|%2Ftmp%2Fhistory|\(value.0)
            R1|1|1|%2Ftmp
            E1|1|prompt||
            """
        let record = try RemoteShellContextRecord(metadata)
        #expect(record.backend == value.0)
        #expect(record.pane == value.1)
        #expect(throws: TerminalRuntimeError.invalidResponse) {
            try RemoteShellContextRecord(metadata.replacingOccurrences(of: "|\(value.1)|ctx.", with: "|bad/pane|ctx."))
        }
    }

    @Test(arguments: kinds)
    func registryAndVersionProbeUseTheSameService(kind: SessionPersistenceBackendID) async throws {
        let versions: [SessionPersistenceBackendID: String] = [
            .tmux: "tmux 3.3a\n", .zellij: "zellij 0.44.3\n",
            .zmx: "zmx\t\t0.7.0\nghostty_vt\t1.2.3\nsocket_dir\t/tmp/zmx\nlog_dir\t/tmp\n",
            .herdr: "herdr 0.7.5\n",
        ]
        let version = try #require(versions[kind])
        let recorder = Recorder([.init(stdout: version, stderr: "", exitCode: 0)])
        let backend = try RemoteSessionBackendRegistry.live.backend(
            kind, execute: { try await recorder.execute($0) })
        #expect(backend is RemoteMultiplexerService)
        let capabilities = try await backend.probe()
        #expect(capabilities.shellIntegration)
        #expect(capabilities.windowCount == (kind == .tmux))
        #expect(capabilities.clientCount == (kind == .tmux || kind == .zmx))
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("command -v \(kind.rawValue)"))
        #expect(command.hasSuffix("\"$exe\" \(kind == .tmux ? "-V" : kind == .zmx ? "version" : "--version")"))
        #expect(!command.contains("new-session"))
    }

    @Test(arguments: [
        ("zellij", "0.44.2", false), ("zellij", "0.44.3", true), ("zellij", "1.0.0", true),
        ("zmx", "0.6.9", false), ("zmx", "0.7.0", true),
        ("herdr", "0.7.4", false), ("herdr", "0.7.5", true), ("herdr", "0.7.99", true),
        ("herdr", "0.8.0", false), ("herdr", "0.8.1", false), ("herdr", "0.8.2", true),
    ])
    func versionBoundaries(value: (String, String, Bool)) throws {
        let kind = try #require(RemoteMultiplexerRegistry.dialect(.init(rawValue: value.0)))
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
    func failuresAndTruncationNeverEnableABackend(kind: SessionPersistenceBackendID) async {
        for (response, expected) in [
            (RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 77), RemoteSessionFailure.missing),
            (.init(stdout: "", stderr: "", exitCode: 79), .ownershipMismatch),
            (.init(stdout: "", stderr: "", exitCode: 81), .startupUnavailable),
            (.init(stdout: "partial", stderr: "", exitCode: 0, truncated: true), .invalidResponse),
            (.init(stdout: "not a version", stderr: "", exitCode: 0), .invalidResponse),
        ] {
            let backend = RemoteMultiplexerService(backend: kind) { _ in response }
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

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func recoveryRejectsReplacedInstancesAndNeverAcquiresManualOwnership(kind: SessionPersistenceBackendID) throws {
        let reference = try Self.reference(kind)
        let backend = RemoteMultiplexerService(backend: kind) { _ in throw CancellationError() }
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
            backend: kind, session: reference.session, hostID: UUID(),
            endpoint: "server:22", username: "user", ownershipToken: nil)
        #expect(try !backend.launch(manual, created: false).attachment.isManaged)
    }

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func identityRoutingAndOwnershipAreRecheckedBeforeClose(kind: SessionPersistenceBackendID) async throws {
        let recorder = Recorder([.init(stdout: "TERMIND_ENDED\n", stderr: "", exitCode: 0)])
        let backend = RemoteMultiplexerService(backend: kind, execute: { try await recorder.execute($0) })
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
            backend: kind, session: reference.session, hostID: UUID(),
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

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func closeFailureAndIncompleteOutputAreNotReportedAsSuccess(kind: SessionPersistenceBackendID) async throws {
        for response in [
            RemoteSessionCommandResult(stdout: "", stderr: "", exitCode: 79),
            .init(stdout: "TERMIND_ENDED", stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_ENDED\n", stderr: "", exitCode: 0, truncated: true),
        ] {
            let service = RemoteMultiplexerService(backend: kind) { _ in response }
            await #expect(throws: (any Error).self) { try await service.terminate(Self.reference(kind)) }
        }
    }

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func confirmedCreateRetriesNeverReplayStartupOrCreateAnotherShell(kind: SessionPersistenceBackendID) async throws {
        let recorder = Recorder([
            .init(stdout: Self.list(kind), stderr: "", exitCode: 0),
            .init(stdout: Self.metadata(kind), stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_CREATED\n", stderr: "", exitCode: 0),
        ])
        let service = RemoteMultiplexerService(backend: kind, execute: { try await recorder.execute($0) })
        let session = try await service.create(
            token: Self.token, startupCommand: "echo NEVER_REPLAY", shellIntegration: true)
        #expect(session.name == Self.name)
        let completion = try #require(await recorder.commands.last)
        #expect(completion.contains("/started"))
        #expect(!completion.contains("NEVER_REPLAY"))
        #expect(!completion.contains("attach --create"))
        #expect(!completion.contains(" server "))
    }

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr])
    func freshCreateInstallsWrapperAndConfirmsTheOwnedIncarnation(kind: SessionPersistenceBackendID) async throws {
        let recorder = Recorder([
            .init(stdout: Self.list(kind, empty: true), stderr: "", exitCode: 0),
            .init(stdout: "TERMIND_CREATED\n", stderr: "", exitCode: 0),
            .init(stdout: Self.list(kind), stderr: "", exitCode: 0),
            .init(stdout: Self.metadata(kind), stderr: "", exitCode: 0),
        ])
        let service = RemoteMultiplexerService(backend: kind, execute: { try await recorder.execute($0) })
        _ = try await service.create(
            token: Self.token, startupCommand: "cd /tmp; export FROM_SNIPPET=yes", shellIntegration: true)
        let create = await recorder.commands[1]
        #expect(create.contains("first-claimed"))
        #expect(create.contains("cd /tmp; export FROM_SNIPPET=yes"))
        #expect(create.contains("TERMIND_CREATED"))
        switch kind {
        case .zellij:
            #expect(create.contains("session_serialization false"))
            #expect(create.contains("--layout-string \"default_shell \\\"$helper/shell\\\""))
        case .zmx:
            #expect(create.contains("termind_owner=\(Self.token.uuidString)"))
            #expect(create.contains("</dev/null"))
        case .herdr:
            #expect(create.contains("SHELL=\"$helper/shell\""))
            #expect(create.contains("HERDR_STARTUP_CWD"))
            #expect(!create.contains("config.toml"))
        default: break
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

    @Test(arguments: [SessionPersistenceBackendID.zellij, .zmx, .herdr]) @MainActor
    func runtimeRequiresUnambiguousClientFocusAndKeepsJournalsBackendScoped(kind: SessionPersistenceBackendID)
        async throws
    {
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
        default: return
        }
        func frame(_ native: String, _ focus: String) -> String {
            "C|987\nN|\(Self.hex(native))\nA|\(Self.hex(focus))\nBEGIN|1\n\(record)\nEND\nDONE\n"
        }
        let update = try RemoteSocketMultiplexerRuntime.parse(frame(native, focus), reference: reference)
        let recorder = Recorder([
            .init(stdout: frame(native, focus), stderr: "", exitCode: 0),
            .init(stdout: frame(native, focus), stderr: "", exitCode: 0),
        ])
        let runtime = RemoteMultiplexerRuntimeAdapter(
            attachment: reference, execute: { try await recorder.execute($0) })
        #expect(
            try await RemoteSocketMultiplexerRuntime(
                reference: reference, execute: { try await recorder.execute($0) }
            )
            .inspect(terminal: "/dev/pts/1") == update)
        let context = try #require(update.contexts.first)
        if kind == .herdr {
            await #expect(throws: TerminalRuntimeError.staleContext) {
                try await runtime.draftTarget(context: context, terminal: "/dev/pts/1", replacing: true)
            }
        } else {
            let target = try await runtime.draftTarget(context: context, terminal: "/dev/pts/1", replacing: true)
            #expect(target.trigger.contains(kind == .zmx ? "\"$exe\" send " : "action write-chars --pane-id"))
            #expect(target.trigger.contains("foreground_shell"))
            #expect(target.root.contains("fingerprint"))
        }
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
    private static func root(_ kind: SessionPersistenceBackendID) -> String {
        kind == .herdr ? "/tmp/test-config/herdr/sessions/\(name)" : "/tmp/\(kind.rawValue)"
    }
    private static func socket(_ kind: SessionPersistenceBackendID) -> String {
        root(kind) + (kind == .herdr ? "/herdr.sock" : "/\(name)")
    }
    private static func list(_ kind: SessionPersistenceBackendID, empty: Bool = false) -> String {
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
        default: return "TERMIND_TMUX_1\n"
        }
    }
    private static func metadata(_ kind: SessionPersistenceBackendID) -> String {
        "F|0|\(hex(socket(kind)))|1:2:3|\(token.uuidString)|/tmp/termind-shell.testing|\(kind == .herdr ? "1:2" : "-")"
            + (kind == .zmx ? "|122|\(hex("Fri Oct 16 10:00:00 2026"))\n" : "|-|-\n")
    }
    private static func reference(_ kind: SessionPersistenceBackendID) throws -> RemoteSessionReference {
        let identity = RemoteMultiplexerIdentity(
            kind: kind, root: root(kind), socket: socket(kind), fingerprint: "1:2:3",
            process: kind == .zmx ? "123" : nil, created: kind == .zmx ? "456" : nil,
            owner: token, helper: "/tmp/termind-shell.testing", isolated: kind == .zellij,
            directoryFingerprint: kind == .herdr ? "1:2" : nil,
            daemonProcess: kind == .zmx ? "122" : nil,
            daemonStarted: kind == .zmx ? "Fri Oct 16 10:00:00 2026" : nil)
        return .init(
            backend: kind,
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

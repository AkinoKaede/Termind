import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct ResumableTerminalEngineTests {
    @Test func recoveryRetryUsesTheExistingEngineWithoutReplayingStartup() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.recovering)
        try await client.retryNow()
        #expect(Array(events.values.suffix(2)) == ["prepareRetry", "retry"])
        #expect(events.values.filter { $0 == "prepare" }.count == 1)
        #expect(events.values.filter { $0.hasPrefix("start:") }.count == 1)
        #expect(!events.values.contains(where: { $0.hasPrefix("write:") }))
        await client.close()
        let closedEvents = events.values
        await events.emit(.recovering)
        await events.emit(.connected)
        #expect(events.values == closedEvents)
    }

    @Test func missingRegistrationFailsBeforeWakeOrBootstrapAndClearsFacadeSecrets() async throws {
        let events = EngineEvents()
        let channel = RemoteConnectionCoordinator(transportEngines: .init(factories: [:])).makePTYChannel(
            output: { _ in }, exit: { _ in })
        await channel.configureTransport(
            .mosh, options: options,
            route: {
                events.record("route")
                throw CancellationError()
            }, stateChanged: { _ in })
        await channel.configureStartup { _ in
            events.record("startup")
            return nil
        }
        let password = SSHSecret("one-use")
        var request = request
        request.configuration.credentials = [.password(password)]
        request.configuration.beforeConnect = { events.record("wake") }
        do {
            try await channel.connect(using: request, columns: 80, rows: 24)
            Issue.record("An unregistered transport must fail before attempting SSH")
        } catch TerminalTransportError.unsupportedRoute {
        }
        #expect(events.values.isEmpty)
        #expect(password.isConsumed)
        await channel.disconnect()
    }

    @Test func coordinatorVariantUsesRegisteredEngineAndRestoresWithoutStartupOrRoute() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let coordinator = RemoteConnectionCoordinator(transportEngines: registry(engine, events: events))
            .withKeyboardInteractive { _ in [] }
        let channel = coordinator.makePTYChannel(
            output: { events.record("output:\(String(decoding: $0, as: UTF8.self))") }, exit: { _ in })
        await channel.configureTransport(
            .mosh, options: options, checkpoint: checkpoint,
            route: {
                events.record("route")
                throw CancellationError()
            }, stateChanged: { events.record("state:\($0)") })
        await channel.configureStartup { _ in
            events.record("startup")
            return nil
        }
        try await channel.connect(using: request, columns: 81, rows: 25)
        #expect(await engine.preparedPayload == checkpoint.payload)
        #expect(await engine.permitsAgentForwarding == false)
        #expect(events.values.contains("start:81x25"))
        #expect(events.values.contains("output:ready"))
        #expect(!events.values.contains("startup"))
        #expect(!events.values.contains("route"))
        await channel.write(Data("hello".utf8))
        await channel.resize(columns: 100, rows: 30, widthPixels: 0, heightPixels: 0)
        await channel.disconnect()
        await channel.disconnect()
        #expect(events.values.contains("write:hello"))
        #expect(events.values.contains("resize:100x30"))
        #expect(events.values.filter { $0 == "close" }.count == 1)
    }

    @Test func suspensionDrainsWritesAndLateActivityCannotUnfreezeTheCheckpoint() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        let writing = Task { try await client.write(Data("hold".utf8)) }
        #expect(await eventually { events.values.contains("write:hold") })
        let suspending = Task { try await client.suspend() }
        #expect(
            await eventually {
                do {
                    try await client.write(Data("probe".utf8))
                    return false
                } catch TerminalTransportError.suspended {
                    return true
                } catch {
                    return false
                }
            })
        #expect(!events.values.contains("checkpoint"))
        await events.emit(.connected)
        await events.emit(.activity)
        await events.emit(.output(Data("tail".utf8)))
        await #expect(throws: TerminalTransportError.self) { try await client.write(Data("blocked".utf8)) }
        try await client.resize(columns: 132, rows: 43)
        #expect(!events.values.contains("resize:132x43"))
        await engine.finishWrite()
        try await writing.value
        let saved = try await suspending.value
        #expect(saved.transport == .mosh)
        #expect(saved.payload == Data("saved-state".utf8))
        #expect(events.values.contains("output:tail"))
        #expect(events.values.last == "state:suspended")
        await events.emit(.connected)
        #expect(events.values.last == "state:suspended")
        try await client.retryNow()
        let retry = events.values.suffix(5)
        #expect(Array(retry) == ["prepareRetry", "beforeResume", "state:recovering", "resume", "resize:132x43"])
        try await client.write(Data("after".utf8))
        #expect(events.values.last == "write:after")
        await client.close()
    }

    @Test func failedStartRollsBackAndClosesTheSelectedEngine() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, failsStart: true)
        let client = client(engine, events: events)
        await #expect(throws: TerminalTransportError.self) { try await connect(client) }
        #expect(Array(events.values.suffix(3)) == ["rollback", "close", "state:closed"])
        await client.close()
        #expect(events.values.filter { $0 == "close" }.count == 1)
    }

    @Test func checkpointCapturesShellEventsEmittedDuringCheckpointPreparation() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events, emitsShellEventDuringCheckpoint: true)
        let client = client(engine, events: events)
        try await connect(client)
        _ = try await client.suspend()
        var filter = try #require(await engine.capturedShell?.commandFilter)
        let update = filter.receive(Data("hello\u{7}visible".utf8))
        #expect(update.events == [.commandStarted("echo hello")])
        #expect(update.visibleOutput == Data("visible".utf8))
        await client.close()
    }

    @Test func remoteEndClosesOnceAndRejectsLateEngineEvents() async throws {
        let events = EngineEvents()
        let engine = TestEngine(events: events)
        let client = client(engine, events: events)
        try await connect(client)
        await events.emit(.ended)
        let ended = events.values
        await events.emit(.output(Data("late".utf8)))
        await events.emit(.connected)
        await events.emit(.ended)
        await client.close()
        #expect(events.values == ended)
        #expect(events.values.filter { $0 == "state:ended" }.count == 1)
        #expect(events.values.filter { $0 == "close" }.count == 1)
        await #expect(throws: CancellationError.self) { try await client.write(Data("late".utf8)) }
    }

    @Test func incompatibleEnvelopeNeverConstructsAnEngine() async throws {
        for invalid in [
            TerminalTransportCheckpoint(transport: .eternalTerminal, payload: Data()),
            {
                var value = checkpoint
                value.version = 99
                return value
            }(),
        ] {
            let events = EngineEvents()
            let engine = TestEngine(events: events)
            let client = ResumableTerminalClient(
                transport: .mosh, checkpoint: invalid, output: { _ in }, stateChanged: { _ in },
                shellIntegration: { _ in }, registry: registry(engine, events: events))
            await #expect(throws: TerminalTransportError.self) { try await connect(client) }
            #expect(events.values.isEmpty)
        }
    }

    @Test func legacyMoshPayloadRemainsTheUnwrappedVendorSnapshot() throws {
        let literal = Data(
            """
            {"endpoint":{"host":"old.example","port":60001,"keyBase64_22":"AAAAAAAAAAAAAAAAAAAAAA"},
             "transportState":"bGVnYWN5LXN0YXRl","createdAtMs":1700000000123,"schemaVersion":2}
            """.utf8)
        let snapshot = try MoshTerminalEngine.decodeCheckpoint(literal)
        #expect(snapshot.endpoint.host == "old.example")
        #expect(snapshot.endpoint.port == 60001)
        #expect(snapshot.transportState == Data("legacy-state".utf8))
        #expect(try json(JSONEncoder().encode(snapshot)) == json(literal))
    }

    @Test func legacyEternalPayloadRetainsFlatKeysAndRestoredShellInput() throws {
        let literal = Data(
            """
            {"clientID":"legacy-client","passkey":"AAECAwQ=",
             "checkpoint":{"reader":{"nonce":"AQID","sequenceNumber":17},
               "writer":{"nonce":"BAUG","sequenceNumber":19,"serializedBackupPackets":["YWJj"]}},
             "integratedShell":{"shell":"zsh","homeDirectory":"/home/legacy"},
             "pendingIntegrationCommand":"cGVuZGluZw=="}
            """.utf8)
        let payload = try EternalTerminalEngine.decodeCheckpoint(literal)
        #expect(payload.clientID == "legacy-client")
        #expect(payload.passkey == Data([0, 1, 2, 3, 4]))
        #expect(payload.shellState.integratedShell?.homeDirectory == "/home/legacy")
        #expect(payload.shellState.pendingIntegrationCommand == Data("pending".utf8))
        #expect(try json(JSONEncoder().encode(payload)) == json(literal))
    }

    private var options: HostTerminalTransports {
        var options = HostTerminalTransports()
        options.moshEnabled = true
        return options
    }

    private var request: SSHConnectionRequest {
        .init(
            configuration: .init(
                hostID: UUID(), host: "127.0.0.1", port: 1, username: "unused", credentials: [], expectedHostKeys: []))
    }

    private var checkpoint: TerminalTransportCheckpoint {
        .init(transport: .mosh, payload: Data("old-state".utf8))
    }

    private func registry(_ engine: TestEngine, events: EngineEvents) -> ResumableTerminalEngineRegistry {
        .init(factories: [
            .mosh: {
                events.install($0)
                events.record("factory")
                return engine
            }
        ])
    }

    private func client(_ engine: TestEngine, events: EngineEvents) -> ResumableTerminalClient {
        .init(
            transport: .mosh, checkpoint: checkpoint,
            output: { events.record("output:\(String(decoding: $0, as: UTF8.self))") },
            stateChanged: { events.record("state:\($0)") }, shellIntegration: { _ in },
            registry: registry(engine, events: events))
    }

    private func connect(_ client: ResumableTerminalClient) async throws {
        try await client.connect(
            request: request, options: options, environment: [], shellIntegrationEnabled: true,
            columns: 80, rows: 24, route: { throw CancellationError() }, progress: nil,
            startupPreparation: { _ in
                Issue.record("Restoring a checkpoint must not prepare a new shell")
                return nil
            })
    }

    private func json(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    private func eventually(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await predicate()
    }
}

private nonisolated final class EngineEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var receive: ResumableTerminalEngine.EventHandler?
    var values: [String] { lock.withLock { recorded } }
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    func install(_ receive: @escaping ResumableTerminalEngine.EventHandler) {
        lock.withLock { self.receive = receive }
    }
    func emit(_ event: ResumableTerminalEngineEvent) async {
        let receive = lock.withLock { self.receive }
        await receive?(event)
    }
}

private actor TestEngine: ResumableTerminalEngine {
    let events: EngineEvents
    let failsStart: Bool
    let emitsShellEventDuringCheckpoint: Bool
    private(set) var preparedPayload: Data?
    private(set) var permitsAgentForwarding = true
    private(set) var capturedShell: ResumableTerminalShellState?
    private var writing: CheckedContinuation<Void, Never>?

    init(events: EngineEvents, failsStart: Bool = false, emitsShellEventDuringCheckpoint: Bool = false) {
        self.events = events
        self.failsStart = failsStart
        self.emitsShellEventDuringCheckpoint = emitsShellEventDuringCheckpoint
    }
    func prepare(_ context: ResumableTerminalEngineContext) async throws -> ResumableTerminalEnginePreparation {
        preparedPayload = context.checkpoint
        permitsAgentForwarding = context.request.permitsAgentForwarding
        events.record("prepare")
        return .init(
            shell: .init(
                commandFilter: emitsShellEventDuringCheckpoint ? RemoteCommandEventFilter(token: "capture") : nil))
    }
    func start(columns: UInt16, rows: UInt16) async throws {
        events.record("start:\(columns)x\(rows)")
        if failsStart { throw TerminalTransportError.unreachable }
        await events.emit(.connected)
        await events.emit(.output(Data("ready".utf8)))
    }
    func write(_ data: Data) async throws {
        events.record("write:\(String(decoding: data, as: UTF8.self))")
        if data == Data("hold".utf8) {
            await withCheckedContinuation { writing = $0 }
        }
    }
    func finishWrite() {
        writing?.resume()
        writing = nil
    }
    func resize(columns: UInt16, rows: UInt16) async throws { events.record("resize:\(columns)x\(rows)") }
    func checkpoint(shell: @Sendable () async -> ResumableTerminalShellState) async throws -> Data {
        events.record("checkpoint")
        if emitsShellEventDuringCheckpoint {
            await events.emit(.output(Data("\u{1b}]777;TermindCommand=capture;echo%20".utf8)))
        }
        capturedShell = await shell()
        return Data("saved-state".utf8)
    }
    func beforeResume() async throws { events.record("beforeResume") }
    func resume() async throws { events.record("resume") }
    func prepareRetry() async { events.record("prepareRetry") }
    func retry() async throws { events.record("retry") }
    func rollback(using bootstrap: SSHConnection) async { events.record("rollback") }
    func close() async {
        events.record("close")
        finishWrite()
    }
}

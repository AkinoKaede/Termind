import ETSession
import Foundation
import TermindApplication
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct EternalTerminalResumeTests {
    @Test func foregroundResumeConfirmsAConnectionThatStayedAliveWithoutANewVendorEvent() async throws {
        let fixture = Fixture()
        await fixture.start()
        fixture.states.continuation.yield(.connected)
        #expect(await eventually { fixture.events.values == [.connected] })

        // The coordinator enters recovery even when ET kept the same connection during suspension.
        await fixture.client.receiveEngineEvent(.recovering)
        try await fixture.engine.resume()
        #expect(fixture.events.values == [.connected, .recovering, .connected])

        await fixture.close()
    }

    @Test(arguments: [ETConnectionState.disconnected, .reconnecting, .failed(.transportFailure("offline"))])
    func foregroundResumeDoesNotConfirmALostConnection(_ state: ETConnectionState) async throws {
        let fixture = Fixture()
        await fixture.start()
        fixture.states.continuation.yield(.connected)
        #expect(await eventually { fixture.events.values == [.connected] })
        fixture.states.continuation.yield(state)
        #expect(await eventually { fixture.events.values.count == 2 })
        let beforeResume = fixture.events.values

        try await fixture.engine.resume()
        #expect(fixture.events.values == beforeResume)

        fixture.states.continuation.yield(.connected)
        #expect(await eventually { fixture.events.values == beforeResume + [.connected] })
        await fixture.close()
    }

    @Test func foregroundResumeCannotReviveAnEndedOrLocallyClosedSession() async throws {
        let fixture = Fixture()
        await fixture.start()
        fixture.states.continuation.yield(.connected)
        #expect(await eventually { fixture.events.values == [.connected] })
        fixture.states.continuation.yield(.sessionEnded)
        fixture.output.continuation.finish()
        #expect(await eventually { fixture.events.values.last == .ended })
        let endedEvents = fixture.events.values

        try await fixture.engine.resume()
        #expect(fixture.events.values == endedEvents)
        #expect(fixture.events.connectionConfirmations == 1)
        await fixture.close()
        await #expect(throws: CancellationError.self) { try await fixture.engine.resume() }
        #expect(fixture.events.values == endedEvents)
        #expect(fixture.events.connectionConfirmations == 1)
    }

    @Test func foregroundResumeBeforeConnectionDoesNotReportSuccess() async throws {
        let fixture = Fixture()
        await fixture.start()
        try await fixture.engine.resume()
        #expect(fixture.events.values.isEmpty)
        #expect(fixture.events.connectionConfirmations == 0)
        await fixture.close()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct Fixture {
    let events: Events
    let client: ResumableTerminalClient
    let engine: EternalTerminalEngine
    let output = AsyncStream<Data>.makeStream()
    let states = AsyncStream<ETConnectionState>.makeStream()

    init() {
        let events = Events()
        let client = ResumableTerminalClient(
            transport: .eternalTerminal,
            output: { _ in },
            stateChanged: { events.record($0) },
            shellIntegration: { _ in })
        self.events = events
        self.client = client
        engine = EternalTerminalEngine {
            if case .connected = $0 { events.recordConnectionConfirmation() }
            await client.receiveEngineEvent($0)
        }
    }

    func start() async {
        await engine.startReaders(output: output.stream, states: states.stream)
    }

    func close() async {
        await client.close()
        await engine.close()
        output.continuation.finish()
        states.continuation.finish()
    }
}

private nonisolated final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ResumableTerminalState] = []
    private var confirmations = 0
    var values: [ResumableTerminalState] { lock.withLock { recorded } }
    var connectionConfirmations: Int { lock.withLock { confirmations } }

    func record(_ state: ResumableTerminalState) {
        lock.withLock { recorded.append(state) }
    }

    func recordConnectionConfirmation() {
        lock.withLock { confirmations += 1 }
    }
}

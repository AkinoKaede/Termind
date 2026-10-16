import ETSession
import Foundation
import MoshCore
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct ResumableTerminalExitTests {
    @Test func moshStoppedDrainsFinalBytesAndEndsOnlyOnce() async throws {
        let events = Events()
        let client = events.client(.mosh)
        let tail = Data("logout\r\n".utf8)

        #expect(await !client.receiveMoshPoll(state: .stopped, operations: [.hostBytes(tail)]))
        #expect(events.values == [.state(.connected), .output(tail), .state(.ended)])
        #expect(await !client.receiveMoshPoll(state: .stopped, operations: [.hostBytes(tail)]))
        await client.close()
        #expect(events.values == [.state(.connected), .output(tail), .state(.ended)])
        await #expect(throws: CancellationError.self) { try await client.write(Data("pwd\n".utf8)) }
        await #expect(throws: CancellationError.self) { try await client.suspend() }
    }

    @Test(arguments: [MoshSessionState.running, .suspended, .failed(.timeout(timeoutMs: 1000))])
    func moshSilenceSuspensionAndFailureAreNotRemoteExit(_ state: MoshSessionState) async {
        let events = Events()
        let client = events.client(.mosh)
        _ = await client.receiveMoshPoll(state: state, operations: [])
        #expect(!events.values.contains(.state(.ended)))
        await client.close()
        _ = await client.receiveMoshPoll(state: .stopped, operations: [])
        #expect(!events.values.contains(.state(.ended)))
    }

    @Test func eternalEndWaitsForTheOutputConsumerBeforeClosing() async {
        let events = Events()
        let client = events.client(.eternalTerminal)
        let output = AsyncStream<Data>.makeStream()
        let states = AsyncStream<ETConnectionState>.makeStream()
        await client.startEternalReaders(output: output.stream, states: states.stream)
        states.continuation.yield(.connected)
        #expect(await eventually { events.values.contains(.state(.connected)) })

        states.continuation.yield(.sessionEnded)
        let tail = Data("last terminal output\r\n".utf8)
        output.continuation.yield(tail)
        #expect(await eventually { events.values.contains(.output(tail)) })
        #expect(!events.values.contains(.state(.ended)))
        output.continuation.finish()

        #expect(await eventually { events.values.contains(.state(.ended)) })
        #expect(events.values == [.state(.connected), .output(tail), .state(.ended)])
        states.continuation.yield(.connected)
        states.continuation.yield(.sessionEnded)
        states.continuation.finish()
        await client.close()
        #expect(events.values == [.state(.connected), .output(tail), .state(.ended)])
    }

    @Test func eternalDisconnectAndOutputEOFAloneDoNotCloseTheSession() async {
        let events = Events()
        let client = events.client(.eternalTerminal)
        let output = AsyncStream<Data>.makeStream()
        let states = AsyncStream<ETConnectionState>.makeStream()
        await client.startEternalReaders(output: output.stream, states: states.stream)
        states.continuation.yield(.disconnected)
        states.continuation.yield(.reconnecting)
        output.continuation.finish()
        #expect(await eventually { events.values.contains(.state(.recovering)) })
        states.continuation.yield(.connected)
        #expect(await eventually { events.values.contains(.state(.connected)) })
        #expect(!events.values.contains(.state(.ended)))
        await client.close()
        states.continuation.yield(.sessionEnded)
        states.continuation.finish()
        #expect(!events.values.contains(.state(.ended)))
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private nonisolated final class Events: @unchecked Sendable {
    enum Event: Equatable {
        case output(Data)
        case state(ResumableTerminalState)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    var values: [Event] { lock.withLock { recorded } }

    func client(_ transport: HostTerminalProtocol) -> ResumableTerminalClient {
        ResumableTerminalClient(
            transport: transport,
            output: { [self] data in lock.withLock { recorded.append(.output(data)) } },
            stateChanged: { [self] state in lock.withLock { recorded.append(.state(state)) } },
            shellIntegration: { _ in })
    }
}

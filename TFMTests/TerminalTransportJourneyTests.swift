import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

@Suite @MainActor
struct TerminalTransportJourneyTests {
    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func initialConnectedEventDoesNotDismissBootstrapJourney(_ transport: HostTerminalProtocol) {
        let host = Host(name: "Server", host: "example.invalid")
        let session = SSHSessionModel(host: host)
        session.transport = transport
        defer { session.disconnect() }
        session.connectionJourney.begin(host: host, route: [host], purpose: .terminal(transport), username: "user")
        session.receiveTransportState(.connected)
        #expect(session.connectionJourney.phase == .connecting)
        #expect(session.connectionJourney.mode == .connection)
        session.receiveTransportState(.failed, failure: "Bootstrap failed")
        #expect(session.connectionJourney.phase == .failed("Bootstrap failed"))
        #expect(session.connectionJourney.transportRecovery == nil)
        #expect(session.connectionJourney.mode == .connection)
        session.receiveTransportState(.closed)
        #expect(session.connectionJourney.phase == .failed("Bootstrap failed"))
    }

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func recoveryPreservesTerminalAndBlocksInteractiveAndBroadcastInput(_ transport: HostTerminalProtocol) async throws
    {
        let host = Host(name: "Server", host: "example.invalid")
        let session = SSHSessionModel(host: host)
        session.transport = transport
        defer { session.disconnect() }
        let surface = session.terminalState
        var writes: [Data] = []
        session.inputSink = { writes.append($0) }

        session.receiveTransportState(.recovering)
        #expect(session.connectionJourney.purpose == .terminal(transport))
        #expect(session.connectionJourney.transportRecovery == .recovering)
        #expect(session.reconnectState == nil)
        session.handleTerminalWrite(Data("interactive".utf8), isInteractiveInput: true)
        session.writeInputDirectly(Data("broadcast".utf8))
        #expect(writes.isEmpty)
        session.handleTerminalWrite(Data("protocol reply".utf8), isInteractiveInput: false)
        #expect(writes == [Data("protocol reply".utf8)])

        session.receiveTransportState(.suspended)
        #expect(session.connectionJourney.transportRecovery == .suspended)
        session.receiveTransportState(.recovering)
        session.receiveTransportState(.connected)
        #expect(session.connectionJourney.phase == .succeeded)
        #expect(!session.acceptsTerminalInput)
        let logs = session.connectionJourney.logs
        session.receiveTransportState(.connected)
        #expect(session.connectionJourney.logs == logs)
        try await Task.sleep(for: .milliseconds(750))
        #expect(session.acceptsTerminalInput)
        #expect(session.terminalState === surface)
        session.writeInputDirectly(Data("after".utf8))
        #expect(writes.last == Data("after".utf8))
    }

    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func failureKeepsOriginalErrorAndClosedSessionIgnoresLateEvents(_ transport: HostTerminalProtocol) {
        let session = SSHSessionModel(host: Host(name: "Server", host: "example.invalid"))
        session.transport = transport
        session.receiveTransportState(.failed, failure: "Transport refused resume")
        #expect(session.connectionJourney.phase == .failed("Transport refused resume"))
        #expect(session.connectionJourney.transportRecovery == .failed)
        #expect(session.reconnectState == nil)
        session.receiveTransportState(.closed)
        #expect(session.connectionJourney.phase == .failed("Transport refused resume"))
        session.disconnect()
        session.receiveTransportState(.recovering)
        session.receiveTransportState(.connected)
        #expect(!session.connectionJourney.isPresented)
        #expect(session.status == .disconnected)
    }
}

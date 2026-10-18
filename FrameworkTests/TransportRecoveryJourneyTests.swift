import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct TransportRecoveryJourneyTests {
    @Test(arguments: [ConnectionPurpose.moshSession, .eternalTerminalSession])
    func recoveryRetainsRouteAndLogsWithoutReplayingAuthentication(_ purpose: ConnectionPurpose) {
        let (journey, host) = fixture(purpose)
        journey.waitForAuthentication(at: host.id)
        journey.resume()
        journey.succeed()
        journey.hide()
        let endpoints = journey.endpoints
        let logs = journey.logs
        journey.showsLogs = true

        journey.updateTransportRecovery(.recovering, message: "Recovering")
        let recoveryLogs = journey.logs
        journey.updateTransportRecovery(.recovering, message: "Recovering")

        #expect(journey.isPresented)
        #expect(journey.mode == .reconnection)
        #expect(journey.purpose == purpose)
        #expect(journey.endpoints == endpoints)
        #expect(journey.logs == recoveryLogs)
        #expect(Array(journey.logs.prefix(logs.count)) == logs)
        #expect(journey.logs.last?.message == "Recovering")
        #expect(journey.showsLogs)
        #expect(journey.checkpoint == nil)
        #expect(journey.completedCheckpoints.isEmpty)
        #expect(journey.activeEndpointIndex == endpoints.count - 1)
    }

    @Test(arguments: [ConnectionPurpose.moshSession, .eternalTerminalSession])
    func suspensionRecoveryAndFailureHaveDistinctPresentation(_ purpose: ConnectionPurpose) {
        let (journey, _) = fixture(purpose)
        journey.updateTransportRecovery(.suspended, message: "Paused")
        #expect(journey.transportRecovery == .suspended)
        journey.updateTransportRecovery(.recovering, message: "Recovering")
        #expect(journey.transportRecovery == .recovering)
        journey.updateTransportRecovery(.failed, message: "Original transport error")
        #expect(journey.phase == .failed("Original transport error"))
        #expect(journey.transportRecovery == .failed)
        let logs = journey.logs
        journey.updateTransportRecovery(.failed, message: "Original transport error")
        #expect(journey.logs == logs)
        journey.hide()
        #expect(journey.transportRecovery == nil)
        #expect(!journey.isPresented)
    }

    @Test(arguments: [ConnectionPurpose.moshSession, .eternalTerminalSession])
    func renewedRecoveryCancelsThePreviousSuccessTimer(_ purpose: ConnectionPurpose) async throws {
        let (journey, _) = fixture(purpose)
        journey.updateTransportRecovery(.recovering, message: "Recovering")
        journey.succeed()
        #expect(journey.phase == .succeeded)
        #expect(journey.transportRecovery == nil)
        journey.updateTransportRecovery(.recovering, message: "Lost again")
        try await Task.sleep(for: .milliseconds(750))
        #expect(journey.phase == .connecting)
        #expect(journey.transportRecovery == .recovering)
        journey.succeed()
        try await Task.sleep(for: .milliseconds(750))
        #expect(!journey.isPresented)
    }

    @Test func ordinaryConnectionFailuresAndSSHReconnectKeepTheirExistingPresentation() {
        let (journey, host) = fixture(.moshSession)
        journey.updateTransportRecovery(.failed, message: "Unavailable")
        journey.begin(host: host, route: [host], purpose: .moshSession, username: "user")
        journey.fail("Bootstrap failed")
        #expect(journey.transportRecovery == nil)
        #expect(journey.mode == .connection)
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "user", mode: .reconnection)
        journey.updateTransportRecovery(.recovering, message: "Must not apply")
        #expect(journey.transportRecovery == nil)
        #expect(!journey.plainTextLog.contains("Must not apply"))
    }

    @Test(arguments: ["authentication", "hostKey", "proxy", "identity", "passphrase"])
    func routeAndProtocolUpdatesDoNotDismissPendingInteraction(kind: String) {
        let (journey, host) = fixture(.eternalTerminalSession)
        switch kind {
        case "authentication": journey.waitForAuthentication(at: host.id)
        case "hostKey": journey.waitForHostKey(at: host.id, fingerprint: "SHA256:test")
        case "proxy": journey.waitForProxyAuthentication(at: host.id)
        case "identity": journey.waitForLocalIdentity(at: host.id)
        default: journey.waitForLocalPassphrase(at: host.id)
        }
        let checkpoint = journey.checkpoint
        let requirement = journey.localRequirement
        let endpoint = journey.activeEndpointIndex
        let attempt = UUID()
        journey.receiveTransportRoute(.init(attemptID: attempt, revision: 1, stage: .opening))
        for recovery in [ConnectionJourney.TransportRecovery.recovering, .suspended, .recovering] {
            journey.updateTransportRecovery(recovery, message: "Recovery changed")
            #expect(journey.phase == .waiting)
            #expect(journey.checkpoint == checkpoint)
            #expect(journey.localRequirement == requirement)
            #expect(journey.activeEndpointIndex == endpoint)
        }
        journey.receiveTransportRoute(.init(attemptID: attempt, revision: 2, stage: .ready))
        #expect(journey.phase == .waiting)
        #expect(journey.checkpoint == checkpoint)
        #expect(journey.localRequirement == requirement)
        journey.resume()
        #expect(journey.phase == .connecting)
        #expect(journey.checkpoint == nil)
        #expect(journey.localRequirement == nil)
    }

    @Test func routeSnapshotsAreIsolatedAndDoNotReviveTheJourneyOrDeclareProtocolReadiness() {
        let (first, host) = fixture(.eternalTerminalSession)
        let second = ConnectionJourney()
        second.begin(host: host, route: [host], purpose: .eternalTerminalSession, username: "user")
        first.succeed()
        first.hide()
        let attempt = UUID()
        let ready = TerminalRouteSnapshot(attemptID: attempt, revision: 2, stage: .ready)
        first.receiveTransportRoute(ready)
        #expect(!first.isPresented)
        #expect(second.transportRoute == nil)
        #expect(second.phase == .connecting)
        first.updateTransportRecovery(.recovering, message: "Recovering")
        first.receiveTransportRoute(ready)
        #expect(first.phase == .connecting)
        first.receiveTransportRoute(.init(attemptID: attempt, revision: 3, stage: .unavailable))
        first.receiveTransportRoute(ready)
        #expect(first.transportRoute?.stage == .unavailable)
        first.begin(host: host, route: [host], purpose: .eternalTerminalSession, username: "user")
        #expect(first.transportRoute == nil)
        first.receiveTransportRoute(.init(attemptID: UUID(), revision: 1, stage: .opening))
        #expect(first.transportRoute?.stage == .opening)
    }

    @Test(arguments: [ConnectionPurpose.moshSession, .sshSession])
    func nonETJourneysIgnoreDataRouteFacts(purpose: ConnectionPurpose) {
        let (journey, _) = fixture(purpose)
        journey.receiveTransportRoute(.init(attemptID: UUID(), revision: 1, stage: .ready))
        #expect(journey.transportRoute == nil)
        #expect(journey.phase == .connecting)
    }

    private func fixture(_ purpose: ConnectionPurpose) -> (ConnectionJourney, Host) {
        let host = Host(name: "Server", host: "example.invalid")
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: purpose, username: "user")
        return (journey, host)
    }
}

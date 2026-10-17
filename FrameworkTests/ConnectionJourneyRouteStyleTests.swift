import SwiftUI
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import TermindPresentation

@Suite @MainActor
struct ConnectionJourneyRouteStyleTests {
    @Test(
        arguments: [
            ConnectionPurpose.sshSession, .moshSession, .eternalTerminalSession,
            .sftpChannel, .metrics, .portForwarding, .keyExport,
        ],
        [1, 2, 3]
    )
    func failureIncludesTheFailingEndpointAndIncomingLineButNotUntouchedRoute(
        purpose: ConnectionPurpose, failedIndex: Int
    ) {
        let (journey, hosts) = fixture(purpose)
        for host in hosts.prefix(failedIndex - 1) {
            journey.receive(.connected(host.id))
        }
        let failedHost = hosts[failedIndex - 1]
        journey.receive(.connecting(failedHost.id))
        journey.fail("Transport failed", at: failedHost.id)

        let style = ConnectionJourneyRouteStyle(journey: journey)
        // The failed endpoint was never completed; it and its incoming line must still be red.
        #expect(journey.completedEndpointIndex < failedIndex)
        #expect(style.state(for: .endpoint, at: failedIndex) == .failed)
        #expect(style.state(for: .segment, at: failedIndex) == .failed)
        expectRoute(
            journey,
            states: Array(repeating: .failed, count: failedIndex + 1)
                + Array(repeating: .pending, count: hosts.count - failedIndex))
    }

    @Test func dataConnectionFailureAfterSSHBootstrapRecolorsTheWholeRouteWithoutMovingFailureAttribution() {
        let (journey, hosts) = fixture(.eternalTerminalSession)
        completeBootstrap(journey, hosts: hosts)
        expectRoute(journey, states: [.complete, .complete, .complete, .complete])

        journey.fail("ET data connection failed", at: hosts[0].id)

        #expect(journey.activeEndpointIndex == 1)
        #expect(journey.logs.last?.endpoint == hosts[0].name)
        #expect(journey.completedCheckpoints[1] == .authentication)
        #expect(journey.completedCheckpoints[2] == .hostKey)
        #expect(journey.completedCheckpoints[3] == .authentication)
        expectRoute(journey, states: [.failed, .failed, .failed, .failed])
    }

    @Test func completedCheckpointStillCountsAsProgressBeforeItsEndpointFinishesConnecting() {
        let (journey, hosts) = fixture(.sshSession)
        journey.receive(.connected(hosts[0].id))
        journey.waitForHostKey(at: hosts[1].id, fingerprint: "SHA256:test")
        journey.resume()
        journey.fail("Jump transport lost", at: hosts[0].id)

        #expect(journey.completedEndpointIndex == 1)
        #expect(journey.completedCheckpoints[2] == .hostKey)
        expectRoute(journey, states: [.failed, .failed, .failed, .pending])
    }

    @Test(arguments: [ConnectionPurpose.moshSession, .eternalTerminalSession])
    func recoveryFailureRecolorsLocalDeviceAllHopsAndAllLines(_ purpose: ConnectionPurpose) {
        let (journey, hosts) = fixture(purpose)
        completeBootstrap(journey, hosts: hosts)
        journey.succeed()
        journey.hide()
        journey.updateTransportRecovery(.suspended, message: "Paused")
        journey.updateTransportRecovery(.recovering, message: "Restoring")
        journey.updateTransportRecovery(.failed, message: "Recovery failed")

        expectRoute(journey, states: [.failed, .failed, .failed, .failed])
        #expect(ConnectionJourneyRouteStyle(journey: journey).activityEndpointIndex == nil)
    }

    @Test func localFailureDoesNotColorAnyRemoteEndpointOrLine() {
        let (journey, hosts) = fixture(.sshSession)
        journey.waitForLocalIdentity(at: hosts[0].id)
        journey.fail("No local identity")

        expectRoute(journey, states: [.failed, .pending, .pending, .pending])
    }

    @Test func proxyFailureIncludesItsSourceHopAndPreviouslyCompletedRoute() {
        let (journey, hosts) = fixture(.eternalTerminalSession)
        journey.receive(.connected(hosts[0].id))
        journey.waitForProxyAuthentication(at: hosts[1].id)
        journey.fail("Proxy rejected authentication")

        expectRoute(journey, states: [.failed, .failed, .pending, .pending])
    }

    @Test func directSerialAndTelnetFailuresUseTheSameInclusiveRule() {
        let journey = ConnectionJourney()
        journey.beginSerial(name: "Serial", address: "/dev/cu.test")
        journey.fail("Port unavailable")
        expectRoute(journey, states: [.failed, .failed])

        let host = Host(name: "Telnet", host: "telnet.example.invalid")
        journey.beginTelnet(host: host, username: nil)
        journey.receive(.openingTransport)
        journey.fail("Transport unavailable")
        expectRoute(journey, states: [.failed, .failed])
    }

    @Test(arguments: [ConnectionPurpose.moshSession, .eternalTerminalSession])
    func retryAndSuccessRemoveFailureColorsWithoutChangingRecoveryActivity(_ purpose: ConnectionPurpose) {
        let (journey, hosts) = fixture(purpose)
        completeBootstrap(journey, hosts: hosts)
        journey.updateTransportRecovery(.failed, message: "Recovery failed")
        expectRoute(journey, states: [.failed, .failed, .failed, .failed])

        journey.updateTransportRecovery(.recovering, message: "Restoring")
        let style = ConnectionJourneyRouteStyle(journey: journey)
        #expect(style.state(for: .endpoint, at: 0) == .complete)
        #expect(style.state(for: .endpoint, at: 1) == .pending)
        #expect(style.state(for: .endpoint, at: 2) == .pending)
        #expect(style.state(for: .endpoint, at: 3) == .active)
        #expect(style.state(for: .segment, at: 1) == .pending)
        #expect(style.state(for: .segment, at: 2) == .pending)
        #expect(style.state(for: .segment, at: 3) == .active)
        #expect(style.activityEndpointIndex == 3)

        journey.updateTransportRecovery(.suspended, message: "Paused")
        #expect(style.state(for: .segment, at: 3) == .pending)
        #expect(style.activityEndpointIndex == nil)

        journey.succeed()
        expectRoute(journey, states: [.complete, .complete, .complete, .complete])
        #expect(style.activityEndpointIndex == nil)
        journey.hide()
    }

    @Test func newConnectionAttemptClearsFailedRouteAndCheckpoints() {
        let (journey, hosts) = fixture(.eternalTerminalSession)
        completeBootstrap(journey, hosts: hosts)
        journey.fail("Data connection failed")
        journey.begin(host: hosts[2], route: hosts, purpose: .eternalTerminalSession, username: "user")

        expectRoute(journey, states: [.complete, .pending, .pending, .pending])
        #expect(journey.completedCheckpoints.isEmpty)
        #expect(ConnectionJourneyRouteStyle(journey: journey).activityEndpointIndex == 0)
    }

    private func fixture(_ purpose: ConnectionPurpose) -> (ConnectionJourney, [Host]) {
        let hosts = [
            Host(name: "Jump One", host: "jump-one.example.invalid"),
            Host(name: "Jump Two", host: "jump-two.example.invalid"),
            Host(name: "Destination", host: "destination.example.invalid"),
        ]
        let journey = ConnectionJourney()
        journey.begin(host: hosts[2], route: hosts, purpose: purpose, username: "user")
        return (journey, hosts)
    }

    private func completeBootstrap(_ journey: ConnectionJourney, hosts: [Host]) {
        for (index, host) in hosts.enumerated() {
            if index == 1 {
                journey.waitForHostKey(at: host.id, fingerprint: "SHA256:test")
            } else {
                journey.waitForAuthentication(at: host.id)
            }
            journey.resume()
            journey.receive(.connected(host.id))
        }
    }

    private func expectRoute(_ journey: ConnectionJourney, states: [ConnectionJourneyRouteStyle.State]) {
        let style = ConnectionJourneyRouteStyle(journey: journey)
        #expect(journey.endpoints.count == states.count)
        for (index, expected) in states.enumerated() {
            #expect(style.state(for: .endpoint, at: index) == expected)
            if expected == .failed {
                #expect(style.state(for: .endpoint, at: index).color == .red)
            }
            if index > 0 {
                // Lines and retained checkpoint badges consume this same segment state and color.
                #expect(style.state(for: .segment, at: index) == expected)
                if expected == .failed {
                    #expect(style.state(for: .segment, at: index).color == .red)
                }
            }
        }
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind
@testable import TermindPresentation

@Suite
@MainActor
struct ConnectionJourneyTests {
    @Test(arguments: [HostTerminalProtocol.mosh, .eternalTerminal])
    func resumableTerminalJourneyUsesTheSelectedTransport(_ transport: HostTerminalProtocol) {
        var host = Host(name: "Server", host: "example.invalid")
        host.terminalTransports.moshEnabled = true
        host.terminalTransports.eternalTerminalEnabled = true
        let store = HostLibraryModel(hosts: [host])
        let session = SSHSessionModel(host: host)
        session.transport = transport
        defer { session.disconnect() }

        session.connect(using: store)

        let purpose = session.connectionJourney.purpose
        #expect(purpose == .terminal(transport))
        #expect(purpose.protocolName == transport.displayName)
        #expect(purpose.symbol(for: .header) == transport.symbol)
        #expect(purpose.symbol(for: .routeDestination) == transport.symbol)
        #expect(session.connectionJourney.plainTextLog.contains("Starting \(transport.displayName) session"))
        #expect(session.connectionJourney.phase == .waiting)

        session.connection.presentReconnectJourney(
            host: host, using: store, purpose: .terminal(transport), username: "user")
        #expect(session.connectionJourney.purpose == purpose)
        #expect(session.connectionJourney.plainTextLog.contains("Reconnecting \(transport.displayName) session"))
    }

    @Test
    func contentSelectionPrioritizesLogsAndPromptsOverRecoveryAndFailure() {
        let host = Host(name: "Server", host: "example.invalid")
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: .moshSession, username: "user")
        journey.updateTransportRecovery(.failed, message: "Resume failed")
        var prompt: SSHAuthenticationPrompt? = .init(host: host, username: "user")
        let reconnect = ReconnectState(attempt: 1, nextRetry: .now, lastError: "Offline")
        func content() -> ConnectionJourneyContent {
            .init(journey: journey, authenticationPrompt: prompt, reconnectState: reconnect)
        }

        journey.showsLogs = true
        guard case .logs = content() else {
            Issue.record("Logs must take precedence over pending interaction")
            return
        }
        journey.showsLogs = false
        guard case .authentication(let selected) = content() else {
            Issue.record("Authentication must take precedence over transport recovery")
            return
        }
        #expect(selected.id == prompt?.id)
        prompt = nil
        guard case .transportRecovery = content() else {
            Issue.record("Transport failure must retain recovery-specific actions")
            return
        }
        journey.fail("Bootstrap failed")
        guard case .failure(let message) = content() else {
            Issue.record("Ordinary failure must take precedence over scheduled reconnect")
            return
        }
        #expect(message == "Bootstrap failed")
        journey.hide()
        guard case .reconnect = content() else {
            Issue.record("An eligible reconnect is shown when no higher-priority content remains")
            return
        }
    }

    @Test
    func telnetUsesItsOwnSymbolThroughoutTheConnectionJourney() {
        #expect(ConnectionPurpose.telnetSession.symbol(for: .header) == "text.rectangle.fill")
        #expect(ConnectionPurpose.telnetSession.symbol(for: .routeDestination) == "text.rectangle.fill")
        #expect(ConnectionPurpose.sshSession.symbol(for: .header) == "apple.terminal.fill")
        #expect(ConnectionPurpose.sshSession.symbol(for: .routeDestination) == "apple.terminal.fill")
        #expect(ConnectionPurpose.sftpChannel.symbol(for: .header) == "folder.fill.badge.gearshape")
        #expect(ConnectionPurpose.sftpChannel.symbol(for: .routeDestination) == "folder.fill")
    }

    @Test
    func routeStartsAtBlueLocalEndpointAndKeepsHostsPending() {
        let jump = Host(name: "Bastion", host: "jump.example")
        var destination = Host(name: "Production", host: "prod.example")
        destination.jumpHostID = jump.id
        let journey = ConnectionJourney()

        journey.begin(
            host: destination, route: [jump, destination],
            purpose: .sshSession, username: "deploy"
        )

        #expect(journey.phase == .connecting)
        #expect(journey.endpoints.count == 3)
        #expect(journey.endpoints[0].role == .local)
        #expect(journey.completedEndpointIndex == 0)
        #expect(journey.activeEndpointIndex == 0)
        #expect(journey.endpoints[1].hostID == jump.id)
        #expect(journey.endpoints[2].hostID == destination.id)
    }

    @Test
    func reconnectUsesTheSameJourneyInReconnectMode() {
        let destination = Host(name: "Production", host: "prod.example")
        let journey = ConnectionJourney()

        journey.begin(
            host: destination, route: [destination],
            purpose: .sshSession, username: "deploy", mode: .reconnection
        )

        #expect(journey.mode == .reconnection)
        #expect(journey.phase == .connecting)
        #expect(journey.isPresented)
    }

    @Test
    func authenticationCheckpointAppearsOnlyWhenRequested() {
        let destination = Host(name: "Server", host: "server.example")
        let journey = ConnectionJourney()
        journey.begin(
            host: destination, route: [destination],
            purpose: .sftpChannel, username: nil
        )

        #expect(journey.checkpoint == nil)
        journey.receive(.connecting(destination.id))
        #expect(journey.checkpoint == nil)

        journey.waitForAuthentication(at: destination.id)
        #expect(journey.phase == .waiting)
        #expect(journey.checkpoint?.kind == .authentication)
        #expect(journey.checkpoint?.endpointIndex == 1)

        journey.resume()
        #expect(journey.phase == .connecting)
        #expect(journey.checkpoint == nil)
        #expect(!journey.waitsForLocalIdentity)
    }

    @Test
    func missingLocalIdentityKeepsEntireRemoteRoutePending() {
        let jump = Host(name: "Bastion", host: "jump.example")
        let destination = Host(name: "Server", host: "server.example")
        let journey = ConnectionJourney()
        journey.begin(
            host: destination, route: [jump, destination],
            purpose: .sshSession, username: nil
        )

        journey.waitForLocalIdentity(at: jump.id)

        #expect(journey.phase == .waiting)
        #expect(journey.checkpoint == nil)
        #expect(journey.waitsForLocalIdentity)
        #expect(journey.completedEndpointIndex == 0)
        #expect(journey.activeEndpointIndex == 0)

        journey.resume()
        #expect(journey.phase == .connecting)
        #expect(!journey.waitsForLocalIdentity)
    }

    @Test
    func localRequirementTransitionsBetweenIdentityAndPassphraseSteps() {
        let destination = Host(name: "Server", host: "server.example")
        let journey = ConnectionJourney()
        journey.begin(
            host: destination, route: [destination],
            purpose: .sshSession, username: "deploy"
        )

        journey.waitForLocalIdentity(at: destination.id)
        #expect(journey.waitsForLocalIdentity)
        #expect(!journey.waitsForLocalPassphrase)

        journey.waitForLocalPassphrase(at: destination.id)
        #expect(journey.waitsForLocalPassphrase)
        #expect(!journey.waitsForLocalIdentity)

        journey.waitForLocalIdentity(at: destination.id)
        #expect(journey.waitsForLocalIdentity)
        #expect(!journey.waitsForLocalPassphrase)

        journey.resume()
        #expect(journey.localRequirement == nil)
    }

    @Test
    func routeProgressIsMonotonicAcrossReconnectProbes() {
        let first = Host(name: "Jump", host: "jump.example")
        let destination = Host(name: "Server", host: "server.example")
        let journey = ConnectionJourney()
        journey.begin(
            host: destination, route: [first, destination],
            purpose: .sshSession, username: "root"
        )

        journey.receive(.connecting(first.id))
        journey.receive(.connected(first.id))
        journey.receive(.connecting(destination.id))
        #expect(journey.completedEndpointIndex == 1)
        #expect(journey.activeEndpointIndex == 2)

        journey.receive(.connecting(first.id))
        #expect(journey.completedEndpointIndex == 1)
        #expect(journey.activeEndpointIndex == 2)
    }

    @Test
    func failureKeepsFutureRoutePendingAndRecordsSanitizedLog() {
        let first = Host(name: "Jump", host: "jump.example")
        let destination = Host(name: "Server", host: "server.example")
        let journey = ConnectionJourney()
        journey.begin(
            host: destination, route: [first, destination],
            purpose: .sshSession, username: "deploy"
        )
        journey.receive(.connected(first.id))
        journey.fail("Connection refused", at: destination.id)

        #expect(journey.phase == .failed("Connection refused"))
        #expect(journey.completedEndpointIndex == 1)
        #expect(journey.activeEndpointIndex == 2)
        #expect(journey.plainTextLog.contains("Connection refused"))
        #expect(!journey.plainTextLog.contains("password"))
    }

    @Test
    func temporaryHostKeyApprovalDoesNotPersist() throws {
        let host = Host(name: "Server", host: "server.example")
        let saved = SSHHostKeyIdentity(
            algorithm: .ed25519, fingerprint: "SHA256:saved"
        )
        let temporary = SSHHostKeyIdentity(
            algorithm: .ed25519, fingerprint: "SHA256:temporary"
        )
        let store = HostLibraryModel(
            hosts: [host],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port,
                    algorithm: saved.algorithm, fingerprint: saved.fingerprint
                )
            ]
        )

        let keys = try store.expectedHostKeys(
            for: host, temporaryHostKeys: [host.id: temporary]
        )

        #expect(keys == [saved, temporary])
        #expect(store.knownHosts(for: host).map(\.identity) == [saved])
    }

    @Test
    func knownHostSetMaintainsOrderingIdempotenceAndForget() throws {
        let host = Host(name: "Server", host: "server.example")
        let first = KnownHostEntry(
            hostname: host.host, algorithm: .ed25519,
            fingerprint: "SHA256:first", addedAt: Date(timeIntervalSince1970: 1)
        )
        let store = HostLibraryModel(hosts: [host], knownHosts: [first])

        store.trust(
            KnownHostEntry(
                hostname: host.host, algorithm: .ed25519,
                fingerprint: "SHA256:second", addedAt: Date(timeIntervalSince1970: 2)
            )
        )
        #expect(store.knownHosts(for: host).map(\.fingerprint) == ["SHA256:second", "SHA256:first"])

        // Re-trusting a known fingerprint refreshes its timestamp without
        // appending a duplicate identity.
        store.trust(
            KnownHostEntry(
                hostname: host.host, algorithm: .ed25519,
                fingerprint: "SHA256:first", addedAt: Date(timeIntervalSince1970: 3)
            )
        )
        #expect(store.knownHosts(for: host).count == 2)
        #expect(store.knownHosts(for: host).map(\.fingerprint) == ["SHA256:first", "SHA256:second"])
        #expect(try store.expectedHostKeys(for: host).count == 2)

        store.forget(knownHost: try #require(store.knownHosts(for: host).last).id)
        #expect(store.knownHosts(for: host).count == 1)

        store.forgetKnownHosts(for: host)
        #expect(store.knownHosts(for: host).isEmpty)
    }

}

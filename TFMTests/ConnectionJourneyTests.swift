import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
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
    func authenticationPromptDistinguishesIdentityCollectionFromServerChallenge() {
        let host = Host(name: "Server", host: "server.example")
        let localPrompt = SSHAuthenticationPrompt(
            host: host, username: "", selectedKeyID: nil,
            failureMessage: nil, mode: .localIdentity
        )
        let serverPrompt = SSHAuthenticationPrompt(
            host: host, username: "deploy", selectedKeyID: nil,
            failureMessage: "Authentication rejected", mode: .serverChallenge
        )

        #expect(localPrompt.mode == .localIdentity)
        #expect(serverPrompt.mode == .serverChallenge)
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
    func temporaryAuthenticationIsScopedToItsJumpHost() throws {
        let jump = Host(name: "Bastion", host: "jump.example")
        var destination = Host(name: "Server", host: "server.example")
        destination.jumpHostID = jump.id
        let store = HostLibraryModel(
            hosts: [jump, destination],
            knownHosts: [
                KnownHostEntry(
                    hostname: jump.host, fingerprint: "SHA256:jump"
                )
            ]
        )
        let submission = SSHAuthenticationSubmission(
            username: "bastion-user", password: "one-use-secret",
            passphrase: nil, keyID: nil
        )

        let configurations = try store.sshJumpConfigurations(
            for: destination, submissions: [jump.id: submission]
        )

        #expect(configurations.count == 1)
        #expect(configurations[0].id == jump.id)
        #expect(configurations[0].username == "bastion-user")
        #expect(store.host(destination.id)?.identityID == nil)
    }

    @Test
    func temporaryHostKeyApprovalDoesNotPersist() throws {
        let host = Host(name: "Server", host: "server.example")
        let store = HostLibraryModel(hosts: [host])
        let temporary = SSHHostKeyIdentity(
            algorithm: .ed25519, fingerprint: "SHA256:temporary"
        )

        let keys = try store.expectedHostKeys(
            for: host, temporaryHostKeys: [host.id: temporary]
        )

        #expect(keys == [temporary])
        #expect(store.knownHosts(for: host).isEmpty)
    }

    @Test
    func temporaryApprovalIsAddedToSavedHostKeys() throws {
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
    }

    @Test
    func hostKeepsMultipleKeysOfTheSameType() throws {
        let host = Host(name: "Server", host: "server.example")
        let first = KnownHostEntry(
            hostname: host.host, algorithm: .ed25519,
            fingerprint: "SHA256:first", addedAt: Date(timeIntervalSince1970: 1)
        )
        let second = KnownHostEntry(
            hostname: host.host, algorithm: .ed25519,
            fingerprint: "SHA256:second", addedAt: Date(timeIntervalSince1970: 2)
        )
        let store = HostLibraryModel(hosts: [host], knownHosts: [first])

        store.trust(second)

        #expect(store.knownHosts(for: host).map(\.fingerprint) == ["SHA256:second", "SHA256:first"])
        #expect(try store.expectedHostKeys(for: host) == [first.identity, second.identity])
    }

    @Test
    func trustingTheSameFingerprintIsIdempotent() {
        let host = Host(name: "Server", host: "server.example")
        let original = KnownHostEntry(
            hostname: host.host, algorithm: .ed25519,
            fingerprint: "SHA256:key", addedAt: Date(timeIntervalSince1970: 1)
        )
        let store = HostLibraryModel(hosts: [host], knownHosts: [original])

        store.trust(
            KnownHostEntry(
                hostname: host.host, algorithm: .ed25519,
                fingerprint: original.fingerprint, addedAt: Date(timeIntervalSince1970: 2)
            )
        )

        let entries = store.knownHosts(for: host)
        #expect(entries.count == 1)
        #expect(entries[0].id == original.id)
        #expect(entries[0].addedAt == Date(timeIntervalSince1970: 2))
    }

    @Test
    func trustAndForgetOperationsApplyToTheHostKeySet() {
        let host = Host(name: "Server", host: "server.example")
        let first = KnownHostEntry(hostname: host.host, fingerprint: "SHA256:first")
        let second = KnownHostEntry(hostname: host.host, fingerprint: "SHA256:second")
        let store = HostLibraryModel(hosts: [host], knownHosts: [first, second])

        store.trust(
            KnownHostEntry(hostname: host.host, fingerprint: "SHA256:third")
        )
        #expect(store.knownHosts(for: host).count == 3)

        store.forget(knownHost: first.id)
        #expect(store.knownHosts(for: host).count == 2)

        store.forgetKnownHosts(for: host)
        #expect(store.knownHosts(for: host).isEmpty)
    }

    @Test
    func hostKeyValidationAcceptsAnyTrustedIdentityAndRejectsUnknownKeys() throws {
        let first = SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:first")
        let second = SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: "SHA256:second")
        let expected: Set<SSHHostKeyIdentity> = [first, second]

        try SSHConnectionOpener.validateHostKey(
            SSHHostKeyObservation(
                hostname: "server.example", port: 22,
                algorithm: second.algorithm, fingerprint: second.fingerprint
            ),
            expected: expected
        )

        #expect(throws: TermindSSHError.self) {
            try SSHConnectionOpener.validateHostKey(
                SSHHostKeyObservation(
                    hostname: "server.example", port: 22,
                    algorithm: .ed25519, fingerprint: "SHA256:unknown"
                ),
                expected: expected
            )
        }
        #expect(throws: TermindSSHError.self) {
            try SSHConnectionOpener.validateHostKey(
                SSHHostKeyObservation(
                    hostname: "server.example", port: 22,
                    algorithm: .ecdsa256, fingerprint: first.fingerprint
                ),
                expected: expected
            )
        }
    }

    @Test
    func hostEditorCommitDoesNotMoveSharedKnownHosts() {
        var host = Host(name: "Server", host: "old.example")
        let shared = Host(name: "Other Login", host: "old.example")
        let entry = KnownHostEntry(hostname: host.host, fingerprint: "SHA256:old")
        let store = HostLibraryModel(hosts: [host, shared], knownHosts: [entry])
        host.host = "new.example"
        host.port = 2222
        #expect(store.saveHost(host))
        #expect(store.knownHosts == [entry])
        #expect(store.knownHosts(for: host).isEmpty)
        #expect(store.knownHosts(for: shared) == [entry])
    }
}

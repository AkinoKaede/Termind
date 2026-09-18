import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct PortForwardingJourneyTests {
    @Test func aCountReceivedWhileStartingSurvivesStartCompletion() async throws {
        let fixture = Fixture(mode: .countDuringStart)
        defer { fixture.controller.stopAll() }
        let rule = fixture.rules[0]
        fixture.controller.start(rule.id)
        try await wait { fixture.controller.state(for: rule.id) == .running(activeConnections: 3) }
    }

    @Test func windowsShareForwardingAuthenticationAndDeletingItsJumpHostCancelsIt() async throws {
        let jump = Host(name: "Jump", host: "jump.invalid")
        let host = Host(name: "Server", host: "server.invalid", jumpHostID: jump.id)
        let rule = PortForwardingRule(hostID: host.id)
        let library = HostLibraryModel(hosts: [jump, host], portForwardings: [rule])
        let app = AppModel(hosts: library)
        defer { app.shutdownForTermination() }
        let first = WindowModel()
        let second = WindowModel()
        first.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
        second.openVaultWork(.forwardingEditor(rule.id), on: .portForwarding)
        app.forwarding.start(rule.id)
        try await wait { app.forwarding.connection(for: rule.id)?.authenticationPrompt != nil }
        let context = try #require(app.forwarding.connection(for: rule.id))
        first.closeVaultWork()
        first.openPage(.snippets)
        #expect(second.vaultWorkRoute == .forwardingEditor(rule.id))
        #expect(context.authenticationPrompt != nil)
        #expect(app.requestHostDeletion(jump.id))
        #expect(context.authenticationPrompt == nil)
        #expect(app.forwarding.state(for: rule.id) == .stopped)
        #expect(app.forwarding.connection(for: rule.id) == nil)
    }

    @Test func savedRulesNeverStartUntilRequestedAndFailureNeverRetries() async throws {
        let fixture = Fixture(mode: .failure)
        let rule = fixture.rules[0]
        #expect(fixture.sessions.isEmpty)
        fixture.controller.start(rule.id)
        try await wait {
            if case .failed = fixture.controller.state(for: rule.id) { return true }
            return false
        }
        #expect(fixture.sessions.count == 1)
        fixture.controller.reconcileConfiguration()
        #expect(fixture.sessions.count == 1)
        #expect(fixture.controller.connection(for: rule.id)?.journey.purpose == .portForwarding)
        fixture.controller.retry(rule.id)
        try await wait { fixture.sessions.count == 2 }
        fixture.controller.stopAll()
    }

    @Test func sharedHostAuthenticatesOnceAndStoppingOneRulePreservesItsPeer() async throws {
        let fixture = Fixture(mode: .keyboard)
        defer { fixture.controller.stopAll() }
        let first = fixture.rules[0]
        let second = fixture.rules[1]
        fixture.controller.start(first.id)
        fixture.controller.start(second.id)
        try await wait {
            fixture.controller.connection(for: first.id)?.connection.keyboardAuthentication.current != nil
        }
        let context = try #require(fixture.controller.connection(for: first.id))
        #expect(context === fixture.controller.connection(for: second.id))
        #expect(fixture.sessions.count == 1)
        fixture.controller.stop(first.id)
        #expect(context.connection.keyboardAuthentication.current != nil)
        try await finishAuthentication(context)
        try await wait { fixture.controller.state(for: second.id) == .running(activeConnections: 0) }
        let session = try #require(fixture.sessions.first)
        #expect(await session.starts == [second.id])
        #expect(fixture.controller.state(for: first.id) == .stopped)
        #expect(!context.journey.plainTextLog.contains("secret-response"))
        #expect(!context.journey.plainTextLog.contains("private instruction"))
    }

    @Test func stoppingTheLastRuleCancelsAuthenticationAndRejectsLateRequestsAndCallbacks() async throws {
        let fixture = Fixture(mode: .keyboard)
        let rule = fixture.rules[0]
        fixture.controller.start(rule.id)
        try await wait { fixture.controller.connection(for: rule.id)?.connection.keyboardAuthentication.current != nil }
        let old = try #require(fixture.controller.connection(for: rule.id))
        let challenge = try #require(old.connection.keyboardAuthentication.current)
        let session = try #require(fixture.sessions.first)
        let request = try #require(await session.requests.first)
        fixture.controller.stop(rule.id)
        #expect(old.connection.keyboardAuthentication.pending.isEmpty)
        fixture.controller.start(rule.id)
        try await wait {
            fixture.sessions.count == 2
                && fixture.controller.connection(for: rule.id)?.connection.keyboardAuthentication.current != nil
        }
        old.connection.keyboardAuthentication.respond(challenge.id, answers: ["stale"])
        await session.fail()
        if let responder = request.keyboardInteractive {
            await #expect(throws: CancellationError.self) { try await responder(challenge) }
        }
        #expect(fixture.controller.state(for: rule.id) == .awaitingAuthentication)
        #expect(old.connection.keyboardAuthentication.pending.isEmpty)
        fixture.controller.stopAll()
    }

    @Test func hostTrustContinuesTheOriginalConnectionAndCanBeTemporary() async throws {
        let fixture = Fixture(mode: .trust)
        defer { fixture.controller.stopAll() }
        let rule = fixture.rules[0]
        fixture.controller.start(rule.id)
        try await wait { fixture.controller.connection(for: rule.id)?.connection.pendingHostKey != nil }
        let context = try #require(fixture.controller.connection(for: rule.id))
        let prompt = try #require(context.connection.pendingHostKey)
        fixture.controller.acceptHostKey(
            for: rule.id, requestID: try #require(context.hostKeyRequestID),
            observation: prompt.observation, remember: false)
        try await wait { fixture.controller.state(for: rule.id) == .running(activeConnections: 0) }
        #expect(fixture.sessions.count == 1)
        #expect(await fixture.sessions[0].requests.count == 1)
        #expect(fixture.library.knownHosts.isEmpty)
    }

    @Test func retiredTrustAndCredentialFormsCannotAuthorizeAReplacementConnection() async throws {
        let trust = Fixture(mode: .trust)
        defer { trust.controller.stopAll() }
        let rule = trust.rules[0]
        trust.controller.start(rule.id)
        try await wait { trust.controller.connection(for: rule.id)?.connection.pendingHostKey != nil }
        let old = try #require(trust.controller.connection(for: rule.id))
        let oldID = try #require(old.hostKeyRequestID)
        let observation = try #require(old.connection.pendingHostKey?.observation)
        trust.controller.stop(rule.id)
        trust.controller.start(rule.id)
        try await wait { trust.controller.connection(for: rule.id)?.connection.pendingHostKey != nil }
        let current = try #require(trust.controller.connection(for: rule.id))
        trust.controller.acceptHostKey(for: rule.id, requestID: oldID, observation: observation, remember: true)
        #expect(current.connection.pendingHostKey != nil)
        #expect(trust.library.knownHosts.isEmpty)
        trust.controller.acceptHostKey(
            for: rule.id, requestID: try #require(current.hostKeyRequestID), observation: observation, remember: true)
        try await wait { trust.controller.state(for: rule.id) == .running(activeConnections: 0) }
        #expect(trust.library.knownHosts.count == 1)

        let credentials = Fixture(mode: .immediate, hasIdentity: false)
        defer { credentials.controller.stopAll() }
        let credentialRule = credentials.rules[0]
        credentials.controller.start(credentialRule.id)
        try await wait { credentials.controller.connection(for: credentialRule.id)?.authenticationPrompt != nil }
        let oldPrompt = try #require(credentials.controller.connection(for: credentialRule.id)?.authenticationPrompt)
        credentials.controller.stop(credentialRule.id)
        credentials.controller.start(credentialRule.id)
        try await wait { credentials.controller.connection(for: credentialRule.id)?.authenticationPrompt != nil }
        credentials.controller.submitAuthentication(
            for: credentialRule.id, promptID: oldPrompt.id, identityID: nil, username: "stale",
            password: "stale", passphrase: nil, keyID: nil, save: true)
        #expect(credentials.library.identities.isEmpty)
        #expect(credentials.controller.state(for: credentialRule.id) == .awaitingAuthentication)
    }

    @Test func encryptedKeyPassphraseResumesPreparationInTheJourney() async throws {
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "forwarding", passphrase: "test-passphrase")
        let key = SSHKeyRef(
            label: "Encrypted", algorithm: .ed25519, publicKey: material.publicKey,
            fingerprint: material.fingerprint, credentialRef: "test-key", storage: .thisDevice, hasPassphrase: true)
        let identity = Identity(name: "Deploy", username: "deploy", keyID: key.id)
        let host = Host(name: "Server", host: "server.invalid", identityID: identity.id)
        let rule = PortForwardingRule(hostID: host.id)
        let library = HostLibraryModel(hosts: [host], identities: [identity], portForwardings: [rule])
        try library.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: material.privateKey)))
        let controller = PortForwardingController(hosts: library) {
            ForwardingTestSession(mode: .immediate, count: $0, failure: $1)
        }
        defer { controller.stopAll() }
        controller.start(rule.id)
        try await wait { controller.connection(for: rule.id)?.authenticationPrompt != nil }
        let context = try #require(controller.connection(for: rule.id))
        let prompt = try #require(context.authenticationPrompt)
        #expect(prompt.requiresPassphrase)
        controller.submitAuthentication(
            for: rule.id, promptID: prompt.id, identityID: identity.id, username: "deploy",
            password: nil, passphrase: "test-passphrase", keyID: key.id, save: false)
        try await wait { controller.state(for: rule.id) == .running(activeConnections: 0) }
        #expect(!context.journey.plainTextLog.contains("test-passphrase"))
    }

    @Test func savedCredentialsContinueTheExplicitOpeningWithoutStartingOtherRules() async throws {
        let fixture = Fixture(mode: .immediate, hasIdentity: false)
        defer { fixture.controller.stopAll() }
        let rule = fixture.rules[0]
        fixture.controller.start(rule.id)
        try await wait { fixture.controller.connection(for: rule.id)?.authenticationPrompt != nil }
        let context = try #require(fixture.controller.connection(for: rule.id))
        let prompt = try #require(context.authenticationPrompt)
        #expect(context.journey.waitsForLocalIdentity)
        fixture.controller.submitAuthentication(
            for: rule.id, promptID: prompt.id, identityID: nil,
            username: "deploy", password: "test-password", passphrase: nil, keyID: nil, save: true)
        try await wait { fixture.controller.state(for: rule.id) == .running(activeConnections: 0) }
        #expect(
            fixture.library.identity(for: try #require(fixture.library.host(fixture.host.id)))?.username == "deploy")
        #expect(fixture.controller.state(for: fixture.rules[1].id) == .stopped)
        #expect(!context.journey.plainTextLog.contains("test-password"))
    }

    @Test func jumpChallengesStayInTheForwardingJourneyAndConfigurationChangesStopIt() async throws {
        let fixture = Fixture(mode: .keyboard, usesJump: true)
        let rule = fixture.rules[0]
        fixture.controller.start(rule.id)
        try await wait { fixture.controller.connection(for: rule.id)?.connection.keyboardAuthentication.current != nil }
        let context = try #require(fixture.controller.connection(for: rule.id))
        let challenge = try #require(context.connection.keyboardAuthentication.current)
        #expect(challenge.hostID == fixture.host.jumpHostID)
        #expect(context.journey.checkpoint?.endpointIndex == 1)
        var jump = try #require(fixture.library.host(challenge.hostID))
        jump.port = 2222
        fixture.library.upsert(jump)
        #expect(fixture.controller.state(for: rule.id) == .stopped)
        #expect(context.connection.keyboardAuthentication.pending.isEmpty)
        #expect(fixture.sessions.count == 1)
    }

    @Test func listenerFailureDoesNotDisconnectAnExistingRuleAndDisconnectNeverRestarts() async throws {
        let fixture = Fixture(mode: .listenerFailure)
        defer { fixture.controller.stopAll() }
        let first = fixture.rules[0]
        let second = fixture.rules[1]
        fixture.controller.start(first.id)
        try await wait { fixture.controller.state(for: first.id) == .running(activeConnections: 0) }
        fixture.controller.start(second.id)
        try await wait {
            if case .failed = fixture.controller.state(for: second.id) { return true }
            return false
        }
        #expect(fixture.controller.state(for: first.id).isActive)
        #expect(fixture.sessions.count == 1)
        let session = try #require(fixture.sessions.first)
        #expect(await session.disconnects == 0)
        await session.fail()
        try await wait {
            if case .failed = fixture.controller.state(for: first.id) { return true }
            return false
        }
        fixture.controller.reconcileConfiguration()
        #expect(fixture.sessions.count == 1)
    }

    @Test func rapidStopAndStartCannotLeaveTheNewListenerStopped() async throws {
        let fixture = Fixture(mode: .immediate)
        defer { fixture.controller.stopAll() }
        let first = fixture.rules[0]
        let second = fixture.rules[1]
        fixture.controller.start(first.id)
        fixture.controller.start(second.id)
        try await wait {
            fixture.rules.allSatisfy { fixture.controller.state(for: $0.id) == .running(activeConnections: 0) }
        }
        fixture.controller.stop(first.id)
        fixture.controller.start(first.id)
        try await wait { fixture.controller.state(for: first.id) == .running(activeConnections: 0) }
        #expect(await fixture.sessions[0].listening == Set(fixture.rules.map(\.id)))
        #expect(fixture.sessions.count == 1)
    }

    private func finishAuthentication(_ context: PortForwardingConnection) async throws {
        let first = try #require(context.connection.keyboardAuthentication.current)
        context.connection.keyboardAuthentication.respond(first.id, answers: ["secret-response"])
        try await wait { context.connection.keyboardAuthentication.current?.round == 2 }
        let second = try #require(context.connection.keyboardAuthentication.current)
        #expect(first.connectionID == second.connectionID && first.id != second.id)
        context.connection.keyboardAuthentication.respond(first.id, answers: ["stale"])
        #expect(context.connection.keyboardAuthentication.current?.id == second.id)
        context.connection.keyboardAuthentication.respond(second.id, answers: [""])
    }

    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.coderInvalidValue)
    }

    @MainActor
    private final class Fixture {
        let host: Host
        let rules: [PortForwardingRule]
        let library: HostLibraryModel
        var sessions: [ForwardingTestSession] = []
        let mode: ForwardingTestSession.Mode
        lazy var controller = PortForwardingController(hosts: library) { [unowned self] count, failure in
            let session = ForwardingTestSession(mode: mode, count: count, failure: failure)
            sessions.append(session)
            return session
        }
        init(mode: ForwardingTestSession.Mode, hasIdentity: Bool = true, usesJump: Bool = false) {
            self.mode = mode
            let identity = Identity(name: "Deploy", username: "deploy")
            let jump = Host(name: "Jump", host: "jump.invalid", identityID: identity.id)
            host = Host(
                name: "Server", host: "server.invalid", identityID: hasIdentity ? identity.id : nil,
                jumpHostID: usesJump ? jump.id : nil)
            rules = [
                PortForwardingRule(hostID: host.id, bindPort: 8000),
                PortForwardingRule(hostID: host.id, bindPort: 9000),
            ]
            library = HostLibraryModel(
                hosts: usesJump ? [jump, host] : [host], identities: hasIdentity ? [identity] : [],
                portForwardings: rules)
            library.willDeletePortForwardings = { [weak self] in self?.controller.stop($0) }
            library.didChangeHostConnection = { [weak self] in self?.controller.hostConfigurationChanged($0) }
        }
    }
}

private actor ForwardingTestSession: SSHForwardingSessionProtocol {
    enum Mode: Sendable { case immediate, keyboard, trust, failure, listenerFailure, countDuringStart }
    let mode: Mode
    let count: SSHForwardingSession.ConnectionHandler
    let failure: SSHForwardingSession.FailureHandler
    var requests: [SSHConnectionRequest] = []
    var starts: [UUID] = []
    var listening: Set<UUID> = []
    var disconnects = 0
    init(
        mode: Mode, count: @escaping SSHForwardingSession.ConnectionHandler,
        failure: @escaping SSHForwardingSession.FailureHandler
    ) {
        self.mode = mode
        self.count = count
        self.failure = failure
    }
    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws {
        requests.append(request)
        let configuration = request.configuration
        if mode == .failure { throw TermindSSHError.disconnected }
        if mode == .trust {
            let observation = SSHHostKeyObservation(
                hostname: configuration.host, port: configuration.port,
                algorithm: .ed25519, fingerprint: "SHA256:test")
            let decision = try await request.authorizeHostKey?(
                SSHHostKeyChallenge(hostID: configuration.hostID, observation: observation, expectedHostKeys: []))
            guard decision == .accept else { throw CancellationError() }
        }
        if mode == .keyboard {
            let connectionID = UUID()
            for round in 1...2 {
                let challenge = SSHKeyboardInteractiveChallenge(
                    connectionID: connectionID,
                    hostID: configuration.jumps.first?.id ?? configuration.hostID,
                    hostname: configuration.host, port: 22, username: configuration.username, round: round,
                    name: "PAM", instruction: "private instruction", prompts: [.init(text: "Code", echo: false)])
                _ = try await request.keyboardInteractive?(challenge)
            }
        }
        try Task.checkCancellation()
        progress?(.connected(configuration.hostID))
    }
    func start(_ rule: PortForwardingRule) async throws {
        if mode == .listenerFailure && rule.bindPort == 9000 { throw TermindSSHError.route("Port in use") }
        if mode == .countDuringStart {
            count(rule.id, 3)
            try await Task.sleep(for: .milliseconds(20))
        }
        starts.append(rule.id)
        listening.insert(rule.id)
    }
    func stop(_ id: UUID) async { listening.remove(id) }
    func disconnect() async {
        disconnects += 1
        listening.removeAll()
    }
    func fail() { failure("Connection lost") }
}

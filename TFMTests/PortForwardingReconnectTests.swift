// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct PortForwardingReconnectTests {
    @Test func numericLimitsUpdateLiveConnectionsAndSurviveRecoveryWithoutChangingHosts() async throws {
        let fixture = ReconnectFixture(poolPolicy: .hostConfigured, connectionLimit: 1, hostConnections: 8)
        defer { fixture.stop() }
        try await fixture.start([0, 1, 2])
        #expect(await fixture.sessions[0].maximumConnections == 1)
        fixture.controller.updateConnectionLimit(64)
        try await eventually { await fixture.sessions[0].maximumConnections == 8 }
        fixture.controller.updateConnectionLimit(1)
        try await eventually { await fixture.sessions[0].maximumConnections == 1 }
        #expect(fixture.library.host(fixture.host.id)?.portForwardingMaxConnections == 8)
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0, 1, 2])
        #expect(await fixture.sessions[1].maximumConnections == 1)
        #expect(!fixture.context!.journey.isPresented)
    }

    @Test func compactLabelsHideConnectionCountsAndFailureDetails() {
        let running = PortForwardingRuntimeState.running(
            activeConnections: 37, sshConnections: 3, targetSSHConnections: 8)
        let failureMessage = "The forwarding transport closed unexpectedly."
        let failed = PortForwardingRuntimeState.failed(failureMessage)

        #expect(running.compactLabel == String(localized: "Running"))
        #expect(running.label == String(localized: "Running · SSH \(3)/\(8) · \(37) TCP flows"))
        #expect(failed.compactLabel == String(localized: "Failed"))
        #expect(failed.label == failureMessage)
        #expect(PortForwardingRuntimeState.reconnecting.compactLabel == String(localized: "Reconnecting"))
    }

    @Test func sharedHostRestoresEveryKindAndJoinsNewRulesWithoutPresentingJourney() async throws {
        let fixture = ReconnectFixture()
        defer { fixture.stop() }
        try await fixture.start([0, 1, 2])
        let context = try #require(fixture.controller.connection(for: fixture.rules[0].id))
        let old = fixture.sessions[0]
        await old.fail()
        try await fixture.waitForRetry()
        fixture.controller.start(fixture.rules[3].id)
        #expect(fixture.sessions.count == 1)
        #expect(fixture.rules.allSatisfy { fixture.controller.state(for: $0.id) == .reconnecting })
        #expect(PortForwardingRuntimeState.reconnecting.isActive)
        #expect(!PortForwardingRuntimeState.reconnecting.isFailed)
        #expect(PortForwardingRuntimeState.reconnecting.label == String(localized: "Reconnecting"))
        #expect(!context.journey.isPresented)
        await fixture.gate.release()
        try await fixture.waitForRunning([0, 1, 2, 3])
        let replacement = fixture.sessions[1]
        #expect(await replacement.starts == Set(fixture.rules.map(\.id)))
        #expect(await replacement.requests.first?.interactionPolicy == .forbidden)
        #expect(await replacement.hasProgress == false)
        #expect(await replacement.requests.first?.configuration.credentials.isEmpty == true)
        #expect(context.connection.reconnectState == nil)
        #expect(context.authenticationPrompt == nil)
        #expect(context.connection.pendingHostKey == nil)
        #expect(context.connection.keyboardAuthentication.pending.isEmpty)
        #expect(!context.journey.isPresented)
        await old.report(fixture.rules[0].id, count: 17)
        await old.fail()
        await fixture.settle()
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .running(activeConnections: 0))
        #expect(fixture.sessions.count == 2)
    }

    @Test func networkFailuresUseCappedBackoffUntilTheConnectionRecovers() async throws {
        let fixture = ReconnectFixture(modes: [.success] + Array(repeating: .offline, count: 5) + [.success])
        defer { fixture.stop() }
        try await fixture.start([0])
        await fixture.sessions[0].fail()
        for (index, delay) in [1, 2, 5, 10, 30, 30].enumerated() {
            try await fixture.waitForRetry()
            let state = try #require(fixture.context?.connection.reconnectState)
            #expect(state.attempt == index + 1)
            #expect(await fixture.gate.nextDelay == .seconds(delay))
            #expect(!fixture.context!.journey.isPresented)
            await fixture.gate.release()
            try await eventually { fixture.sessions.count == index + 2 }
        }
        try await fixture.waitForRunning([0])
        #expect(fixture.context?.connection.reconnectState == nil)
    }

    @Test func restartingOneRuleOnTheSameTransportRejectsItsOldCounts() async throws {
        let fixture = ReconnectFixture()
        defer { fixture.stop() }
        try await fixture.start([0, 1])
        let session = fixture.sessions[0]
        let id = fixture.rules[0].id
        let oldGeneration = try #require(await session.generations[id])
        fixture.controller.stop(id)
        fixture.controller.start(id)
        try await fixture.waitForRunning([0, 1])
        let newGeneration = try #require(await session.generations[id])
        #expect(newGeneration != oldGeneration)
        #expect(fixture.sessions.count == 1)
        await session.report(id, generation: newGeneration, count: 2)
        try await eventually { fixture.controller.state(for: id) == .running(activeConnections: 2) }
        await session.report(id, generation: oldGeneration, count: 17)
        await fixture.settle()
        #expect(fixture.controller.state(for: id) == .running(activeConnections: 2))
    }

    @Test(arguments: [ReconnectSession.Mode.keyboard, .trust], [false, true])
    fileprivate func interactionOnDestinationOrJumpEndsRecoveryWithoutOpeningForms(
        _ mode: ReconnectSession.Mode, _ jump: Bool
    ) async throws {
        let fixture = ReconnectFixture(modes: [.success, mode, mode], usesJump: jump, trusted: mode != .trust)
        defer { fixture.stop() }
        try await fixture.start([0])
        let context = try #require(fixture.context)
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await eventually { fixture.controller.state(for: fixture.rules[0].id).isFailed }
        #expect(
            fixture.controller.state(for: fixture.rules[0].id) == .failed(SSHInteractionRequired().localizedDescription)
        )
        #expect(context.connection.reconnectState == nil)
        #expect(context.connection.keyboardAuthentication.pending.isEmpty)
        #expect(context.connection.pendingHostKey == nil)
        #expect(context.authenticationPrompt == nil)
        #expect(!context.journey.isPresented)
        fixture.controller.retry(fixture.rules[0].id)
        try await eventually {
            fixture.context?.connection.keyboardAuthentication.current != nil
                || fixture.context?.connection.pendingHostKey != nil
        }
        #expect(fixture.sessions.count == 3)
        #expect(fixture.context !== context)
        #expect(fixture.context?.journey.isPresented == true)
        #expect(await fixture.sessions[2].requests.first?.interactionPolicy == .allowed)
    }

    @Test(arguments: [
        TermindSSHError.authenticationFailed("Rejected"), .missingCredential, .keyPassphraseRequired,
        .missingUsername, .untrustedHost, .mismatchedHostKey, .hostKeyChanged(expected: ["old"], received: "new"),
        .routeHost(hostID: UUID(), authentication: true, serverChallenge: true, hostKey: false, message: "Jump auth"),
        .routeHost(hostID: UUID(), authentication: false, serverChallenge: false, hostKey: true, message: "Jump trust"),
    ])
    func authenticationAndTrustErrorsRequireManualRetry(_ error: TermindSSHError) async throws {
        let fixture = ReconnectFixture()
        defer { fixture.stop() }
        try await fixture.start([0])
        fixture.nextError = error
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await eventually { fixture.controller.state(for: fixture.rules[0].id).isFailed }
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .failed(error.localizedDescription))
        #expect(fixture.context?.journey.isPresented == false)
        #expect(fixture.context?.authenticationPrompt == nil)
        #expect(fixture.context?.connection.reconnectState == nil)
    }

    @Test(arguments: [false, true])
    func onlyRememberedHostTrustCanAuthorizeRecovery(_ remember: Bool) async throws {
        let fixture = ReconnectFixture(modes: [.trust, .trust], trusted: false)
        defer { fixture.stop() }
        fixture.controller.start(fixture.rules[0].id)
        try await eventually { fixture.context?.connection.pendingHostKey != nil }
        let context = try #require(fixture.context)
        fixture.controller.acceptHostKey(
            for: fixture.rules[0].id, requestID: try #require(context.hostKeyRequestID),
            observation: try #require(context.connection.pendingHostKey?.observation), remember: remember)
        try await fixture.waitForRunning([0])
        await fixture.sessions[0].fail()
        try await fixture.retry()
        if remember {
            try await fixture.waitForRunning([0])
        } else {
            try await eventually { fixture.controller.state(for: fixture.rules[0].id).isFailed }
        }
        let request = try #require(await fixture.sessions[1].requests.first)
        #expect(request.configuration.expectedHostKeys.isEmpty == !remember)
        #expect(fixture.library.knownHosts.isEmpty == !remember)
        #expect(!context.journey.isPresented)
    }

    @Test func temporaryPasswordAndKeyPassphraseAreAbsentFromRecoverySnapshot() async throws {
        let fixture = ReconnectFixture()
        defer { fixture.stop() }
        let material = try SSHKeyMaterial.generate(.ed25519, comment: "recovery", passphrase: "temporary-passphrase")
        let key = SSHKeyRef(
            label: "Encrypted", algorithm: .ed25519, publicKey: material.publicKey, fingerprint: material.fingerprint,
            credentialRef: "recovery-key", storage: .thisDevice, hasPassphrase: true)
        try fixture.library.upsert(key, credential: .software(SSHPrivateKeySecret(privateKey: material.privateKey)))
        var identity = fixture.identity
        identity.keyID = key.id
        fixture.library.upsert(identity)
        fixture.controller.start(fixture.rules[0].id)
        try await eventually { fixture.context?.authenticationPrompt != nil }
        let prompt = try #require(fixture.context?.authenticationPrompt)
        fixture.controller.submitAuthentication(
            for: fixture.rules[0].id, promptID: prompt.id, identityID: identity.id, username: identity.username,
            password: "temporary-password", passphrase: "temporary-passphrase", keyID: key.id, save: false)
        try await fixture.waitForRunning([0])
        await fixture.sessions.last!.fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0])
        let request = try #require(await fixture.sessions.last!.requests.first)
        #expect(request.interactionPolicy == .forbidden)
        #expect(request.configuration.credentials.count == 1)
        guard case .interactionRequired = request.configuration.credentials[0] else {
            Issue.record("Expected a reference-only interaction marker")
            return
        }
        #expect(fixture.library.identity(identity.id)?.usesPassword == false)
        #expect(fixture.context?.journey.plainTextLog.contains("temporary-") == false)
    }

    @Test func stoppingOneRuleDuringBackoffPreservesOnlyItsPeer() async throws {
        let fixture = ReconnectFixture()
        defer { fixture.stop() }
        try await fixture.start([0, 1])
        await fixture.sessions[0].fail()
        try await fixture.waitForRetry()
        fixture.controller.stop(fixture.rules[0].id)
        await fixture.gate.release()
        try await fixture.waitForRunning([1])
        #expect(await fixture.sessions[1].starts == [fixture.rules[1].id])
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .stopped)
    }

    @Test(arguments: ["stop", "remove", "host", "jump", "rule", "all"])
    func retiringIntentRejectsEvenAnUncooperativeRetryTimer(_ action: String) async throws {
        let fixture = ReconnectFixture(usesJump: true)
        defer { fixture.stop() }
        try await fixture.start([0])
        let context = try #require(fixture.context)
        await fixture.sessions[0].fail()
        try await fixture.waitForRetry()
        fixture.retire(action, index: 0)
        await fixture.gate.release()
        await fixture.settle()
        #expect(fixture.sessions.count == 1)
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .stopped)
        #expect(fixture.context == nil)
        #expect(context.connection.reconnectState == nil)
    }

    @Test(arguments: ["stop", "remove", "host", "jump", "rule", "all"], [false, true])
    func retiringDuringRecoveryRejectsLateOpeningAndListenerSuccess(_ action: String, _ listening: Bool) async throws {
        let fixture = ReconnectFixture(modes: [.success, listening ? .holdLateStart : .holdConnect], usesJump: true)
        defer { fixture.stop() }
        try await fixture.start([1])
        let context = try #require(fixture.controller.connection(for: fixture.rules[1].id))
        await fixture.sessions[0].fail()
        try await fixture.retry()
        let session = fixture.sessions[1]
        try await eventually { await (listening ? session.hasPendingStart : session.waitingToConnect) }
        fixture.retire(action, index: 1)
        if listening { await session.releaseStart() } else { await session.releaseConnect() }
        try await eventually { await session.disconnects > 0 }
        await fixture.settle()
        #expect(fixture.controller.state(for: fixture.rules[1].id) == .stopped)
        #expect(fixture.controller.connection(for: fixture.rules[1].id) == nil)
        #expect(context.connection.reconnectState == nil)
        #expect(!context.journey.isPresented)
        #expect(await session.listening.isEmpty)
        #expect(fixture.sessions.count == 2)
    }

    @Test(arguments: [false, true])
    func stopAndStartOnASharedTransportRejectsLateListenerResults(_ fails: Bool) async throws {
        let fixture = ReconnectFixture(modes: [.success, .holdLateStart])
        defer { fixture.stop() }
        try await fixture.start([0, 1])
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0])
        let session = fixture.sessions[1]
        try await eventually { await session.hasPendingStart }
        let id = fixture.rules[1].id
        let oldGeneration = try #require(await session.generations[id])
        fixture.controller.stop(id)
        fixture.controller.start(id)
        await session.releaseStart(failing: fails)
        try await eventually {
            guard await session.generations[id] != oldGeneration else { return false }
            return await session.hasPendingStart
        }
        await session.releaseStart()
        try await fixture.waitForRunning([0, 1])
        #expect(fixture.sessions.count == 2)
        #expect(!fixture.context!.journey.isPresented)
        #expect(await session.listening == [fixture.rules[0].id, id])
    }

    @Test func stopAndStartDuringOpeningRejectsItsLateSuccessAndWaitsForCleanup() async throws {
        let fixture = ReconnectFixture(modes: [.success, .holdConnect, .success])
        defer { fixture.stop() }
        try await fixture.start([0])
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await eventually { await fixture.sessions[1].waitingToConnect }
        let old = fixture.sessions[1]
        fixture.controller.stop(fixture.rules[0].id)
        fixture.controller.start(fixture.rules[0].id)
        try await eventually { fixture.sessions.count == 3 }
        #expect(await fixture.sessions[2].requests.isEmpty)
        await old.releaseConnect()
        try await fixture.waitForRunning([0])
        #expect(await old.starts.isEmpty)
        #expect(await old.disconnects > 0)
        #expect(await fixture.sessions[2].requests.first?.interactionPolicy == .allowed)
        await old.fail()
        await fixture.settle()
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .running(activeConnections: 0))
    }

    @Test func recoveryWaitsForTheOldListenerToFinishClosingBeforeOpeningItsReplacement() async throws {
        let fixture = ReconnectFixture(modes: [.holdDisconnect, .success])
        defer { fixture.stop() }
        try await fixture.start([0])
        let old = fixture.sessions[0]
        await old.fail()
        try await fixture.retry()
        try await eventually {
            guard fixture.sessions.count == 2 else { return false }
            return await old.waitingToDisconnect
        }
        #expect(await fixture.sessions[1].requests.isEmpty)
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .reconnecting)
        await old.releaseDisconnect()
        try await fixture.waitForRunning([0])
        #expect(await fixture.sessions[1].starts == [fixture.rules[0].id])
    }

    @Test func pendingListenerCancellationCannotEraseRecoveryAndStopDoesNotWaitForItsStart() async throws {
        let fixture = ReconnectFixture(modes: [.holdRemoteStart, .holdRemoteStart])
        defer { fixture.stop() }
        try await fixture.start([0])
        fixture.controller.start(fixture.rules[1].id)
        try await eventually { await fixture.sessions[0].hasPendingStart }
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0])
        try await eventually { await fixture.sessions[1].hasPendingStart }
        #expect(fixture.controller.state(for: fixture.rules[1].id) == .reconnecting)
        fixture.controller.stop(fixture.rules[1].id)
        try await eventually { await !fixture.sessions[1].hasPendingStart }
        #expect(fixture.controller.state(for: fixture.rules[0].id) == .running(activeConnections: 0))
        #expect(fixture.controller.state(for: fixture.rules[1].id) == .stopped)
    }

    @Test func listenerFailureDuringRecoveryIsLocalAndStaysOutOfJourney() async throws {
        let fixture = ReconnectFixture(modes: [.success, .remoteListenerFailure])
        defer { fixture.stop() }
        try await fixture.start([0, 1])
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0])
        try await eventually { fixture.controller.state(for: fixture.rules[1].id).isFailed }
        #expect(!fixture.context!.journey.isPresented)
        await fixture.sessions[1].fail()
        try await fixture.retry()
        try await fixture.waitForRunning([0])
        #expect(await fixture.sessions[2].starts == [fixture.rules[0].id])
    }

    @Test func transportLossWhileStartingAListenerKeepsTheRuleInRecovery() async throws {
        let fixture = ReconnectFixture(modes: [.success, .disconnectedListener, .success])
        defer { fixture.stop() }
        try await fixture.start([1])
        await fixture.sessions[0].fail()
        try await fixture.retry()
        try await fixture.waitForRetry()
        #expect(fixture.controller.state(for: fixture.rules[1].id) == .reconnecting)
        #expect(await fixture.gate.nextDelay == .seconds(2))
        await fixture.gate.release()
        try await fixture.waitForRunning([1])
        #expect(await fixture.sessions[2].starts == [fixture.rules[1].id])
        #expect(fixture.controller.connection(for: fixture.rules[1].id)?.journey.isPresented == false)
    }
}

@MainActor
private final class ReconnectFixture {
    let identity = Identity(name: "User", username: "user")
    let jump: Host
    let host: Host
    let rules: [PortForwardingRule]
    let library: HostLibraryModel
    let gate = ForwardingRetryGate()
    var sessions: [ReconnectSession] = []
    var nextError: TermindSSHError?
    let modes: [ReconnectSession.Mode]
    let poolPolicy: PortForwardingController.PoolPolicy
    let connectionLimit: Int
    lazy var controller = makeController()

    private func makeController() -> PortForwardingController {
        let makeConnection: PortForwardingController.ConnectionFactory = { [unowned self] count, failure in
            let mode = sessions.count < modes.count ? modes[sessions.count] : .success
            let session = ReconnectSession(mode: mode, error: nextError, count: count, failure: failure)
            nextError = nil
            sessions.append(session)
            return session
        }
        return PortForwardingController(
            hosts: library, poolPolicy: poolPolicy, connectionLimit: connectionLimit, makeConnection: makeConnection,
            makeReconnectController: { [gate] in
                SessionReconnectController(policy: .sessionDefault, sleep: { await gate.sleep($0) }, now: Date.init)
            })
    }
    var context: PortForwardingConnection? { controller.connection(for: rules[0].id) }

    init(
        modes: [ReconnectSession.Mode] = [], usesJump: Bool = false, trusted: Bool = true,
        poolPolicy: PortForwardingController.PoolPolicy = .singleConnection, connectionLimit: Int = 64,
        hostConnections: Int = 1
    ) {
        self.modes = modes
        self.poolPolicy = poolPolicy
        self.connectionLimit = connectionLimit
        jump = Host(name: "Jump", host: "jump.invalid", identityID: identity.id)
        host = Host(
            name: "Host", host: "host.invalid", identityID: identity.id, jumpHostID: usesJump ? jump.id : nil,
            portForwardingMaxConnections: hostConnections)
        rules = [
            PortForwardingRule(hostID: host.id, kind: .local, bindPort: 8000),
            PortForwardingRule(hostID: host.id, kind: .remote, bindPort: 9000),
            PortForwardingRule(hostID: host.id, kind: .dynamic, bindPort: 1080),
            PortForwardingRule(hostID: host.id, kind: .local, bindPort: 8001),
        ]
        library = HostLibraryModel(
            hosts: usesJump ? [jump, host] : [host], identities: [identity],
            portForwardings: rules,
            knownHosts: trusted
                ? [jump, host].map {
                    KnownHostEntry(hostname: $0.host, port: 22, algorithm: .ed25519, fingerprint: "trusted")
                } : [])
        library.willDeletePortForwardings = { [weak self] in self?.controller.stop($0) }
    }

    func start(_ indices: [Int]) async throws {
        for index in indices { controller.start(rules[index].id) }
        try await waitForRunning(indices)
    }
    func waitForRunning(_ indices: [Int]) async throws {
        try await eventually {
            indices.allSatisfy { self.controller.state(for: self.rules[$0].id) == .running(activeConnections: 0) }
        }
    }
    func waitForRetry() async throws {
        try await eventually { await self.gate.nextDelay != nil }
    }
    func retry() async throws {
        try await waitForRetry()
        let count = sessions.count
        await gate.release()
        try await eventually { self.sessions.count == count + 1 }
    }
    func settle() async { for _ in 0..<30 { await Task.yield() } }
    func retire(_ action: String, index: Int) {
        switch action {
        case "stop": controller.stop(rules[index].id)
        case "remove": controller.remove([rules[index].id])
        case "host": controller.hostConfigurationChanged(host.id)
        case "jump": controller.hostConfigurationChanged(jump.id)
        case "rule":
            var rule = rules[index]
            rule.bindPort += 10
            library.upsert(rule)
        default: controller.stopAll()
        }
    }
    func stop() {
        controller.stopAll()
        Task { await gate.finish() }
    }
}

private actor ForwardingRetryGate {
    private var pending: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var finished = false
    var nextDelay: Duration? { pending.first?.0 }
    func sleep(_ duration: Duration) async {
        guard !finished else { return }
        await withCheckedContinuation { pending.append((duration, $0)) }
    }
    func release() { if !pending.isEmpty { pending.removeFirst().1.resume() } }
    func finish() {
        finished = true
        while !pending.isEmpty { release() }
    }
}

private actor ReconnectSession: SSHForwardingConnectionProtocol {
    enum Mode: Sendable {
        case success, offline, keyboard, trust, holdConnect, holdDisconnect, holdRemoteStart, holdLateStart
        case remoteListenerFailure, disconnectedListener
    }
    let mode: Mode
    let error: TermindSSHError?
    let count: SSHForwardingConnection.ConnectionHandler
    let failure: SSHForwardingConnection.FailureHandler
    var requests: [SSHConnectionRequest] = []
    var starts: Set<UUID> = []
    var listening: Set<UUID> = []
    var generations: [UUID: UUID] = [:]
    var hasProgress = false
    var disconnects = 0
    var maximumConnections = 1
    func updateMaximumConnections(_ maximum: Int) async { maximumConnections = maximum }
    private var connectGate: CheckedContinuation<Void, Never>?
    private var disconnectGate: CheckedContinuation<Void, Never>?
    private var pendingStarts: [UUID: CheckedContinuation<Void, any Error>] = [:]
    var waitingToConnect: Bool { connectGate != nil }
    var waitingToDisconnect: Bool { disconnectGate != nil }
    var hasPendingStart: Bool { !pendingStarts.isEmpty }

    init(
        mode: Mode, error: TermindSSHError?, count: @escaping SSHForwardingConnection.ConnectionHandler,
        failure: @escaping SSHForwardingConnection.FailureHandler
    ) {
        self.mode = mode
        self.error = error
        self.count = count
        self.failure = failure
    }
    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws {
        requests.append(request)
        hasProgress = progress != nil
        if let error { throw error }
        if mode == .offline { throw TermindSSHError.socket("Offline") }
        if mode == .holdConnect { await withCheckedContinuation { connectGate = $0 } }
        let configuration = request.configuration
        let hop = configuration.jumps.first
        if mode == .keyboard {
            _ = try await request.keyboardInteractive?(
                SSHKeyboardInteractiveChallenge(
                    connectionID: UUID(), hostID: hop?.id ?? configuration.hostID,
                    hostname: hop?.host ?? configuration.host, port: 22, username: "user", round: 1,
                    name: "OTP", instruction: "", prompts: [.init(text: "Code", echo: false)]))
        }
        if mode == .trust {
            let observation = SSHHostKeyObservation(
                hostname: hop?.host ?? configuration.host, port: 22, algorithm: .ed25519, fingerprint: "trusted")
            let keys = hop?.expectedHostKeys ?? configuration.expectedHostKeys
            if !keys.contains(observation.identity) {
                _ = try await request.authorizeHostKey?(
                    SSHHostKeyChallenge(
                        hostID: hop?.id ?? configuration.hostID, observation: observation, expectedHostKeys: keys))
            }
        }
        progress?(.connected(configuration.hostID))
    }
    func start(_ rule: PortForwardingRule, generation: UUID) async throws {
        generations[rule.id] = generation
        if rule.kind == .remote {
            if mode == .remoteListenerFailure { throw TermindSSHError.route("Port in use") }
            if mode == .disconnectedListener { throw TermindSSHError.disconnected }
            if mode == .holdRemoteStart || mode == .holdLateStart {
                try await withCheckedThrowingContinuation { pendingStarts[rule.id] = $0 }
            }
        }
        starts.insert(rule.id)
        listening.insert(rule.id)
    }
    func stop(_ id: UUID) {
        listening.remove(id)
        if mode != .holdLateStart { pendingStarts.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    }
    func disconnect() async {
        disconnects += 1
        if mode == .holdDisconnect { await withCheckedContinuation { disconnectGate = $0 } }
        listening.removeAll()
        if mode != .holdLateStart { cancelStarts() }
    }
    func releaseDisconnect() {
        disconnectGate?.resume()
        disconnectGate = nil
    }
    func releaseConnect() {
        connectGate?.resume()
        connectGate = nil
    }
    func releaseStart(failing: Bool = false) {
        let pending = pendingStarts.values
        pendingStarts.removeAll()
        for continuation in pending {
            if failing {
                continuation.resume(throwing: TermindSSHError.route("Late listen failure"))
            } else {
                continuation.resume()
            }
        }
    }
    func fail() {
        cancelStarts()
        failure("Connection lost")
    }
    func report(_ id: UUID, generation: UUID? = nil, count value: Int) {
        guard let generation = generation ?? generations[id] else { return }
        count(id, generation, value)
    }
    private func cancelStarts() {
        let pending = pendingStarts.values
        pendingStarts.removeAll()
        for continuation in pending { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor
private func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<2000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    throw CocoaError(.coderInvalidValue)
}

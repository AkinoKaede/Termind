// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct MetricsJourneyTests {
    @Test func metricsWorkerReturnsToMainActorAfterBackgroundSamplerCallbacks() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        host.identityID = identity.id
        let hosts = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        try hosts.upsert(identity, passwordUpdate: .replace("test-only"))
        let sampler = BackgroundResumingMetricsSampler()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(),
            makeSampler: { sampler })
        defer { model.shutdown() }

        #expect(model.add(host))
        let server = try #require(model.servers.first)
        try await wait { server.point != nil }

        #expect(server.collectionState == .live)
        #expect(sampler.snapshot().connections == 1)
        #expect(sampler.snapshot().samples >= 1)
    }

    @Test func offlineRestoredMetricsReconcileOnMainActor() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        host.identityID = identity.id
        let hosts = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        try hosts.upsert(identity, passwordUpdate: .replace("test-only"))
        let clock = PortMetricsClock()
        let preferences = PortMetricsPreferences(selections: [MetricsSelection(id: host.id)])
        let model = ServerMetricsModel(
            hosts: hosts, preferences: preferences,
            makeSampler: { FailingMetricsSampler() },
            clock: clock.clock)
        defer { model.shutdown() }

        model.start()
        let server = try #require(model.servers.first)
        try await wait { server.collectionState == .failed && clock.delays.count >= 2 }

        host.name = "Renamed Monitor"
        hosts.upsert(host)
        clock.advance(2)

        try await wait { server.name == host.name && server.collectionState == .failed }
        #expect(server.collectionState == .failed)

        model.suspend()
        clock.advance(2)
        #expect(model.snapshot(for: host.id)?.state == .sleeping)
        model.resume()
        model.remove(host.id)
        clock.advance(2)
        #expect(model.servers.isEmpty)
        model.shutdown()
        clock.advance(2)
        #expect(model.servers.isEmpty)
    }

    @Test func failurePublishesAnInitializedMetricsJourney() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        var host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        host.identityID = identity.id
        let hosts = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [
                KnownHostEntry(
                    hostname: host.host, port: host.port, algorithm: .ed25519,
                    fingerprint: "SHA256:test")
            ])
        try hosts.upsert(identity, passwordUpdate: .replace("test-only"))
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(),
            makeSampler: { FailingMetricsSampler() })
        defer { model.shutdown() }

        #expect(model.add(host))
        let server = try #require(model.servers.first)
        #expect(server.journey.purpose == .metrics)
        #expect(server.journey.endpoints.count == 2)
        #expect(server.journey.destination?.hostID == host.id)

        try await wait {
            if case .failed = server.journey.phase { return true }
            return false
        }

        #expect(server.collectionState == .failed)
        #expect(server.journey.endpoints.count == 2)
    }

    @Test func temporarySecretStoreFailureRetriesWithoutRequestingAuthentication() async throws {
        let identity = Identity(
            name: "Deploy", username: "deploy",
            credentialRef: "termind.password.test"
        )
        var host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        host.identityID = identity.id
        let hosts = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")],
            secrets: UnavailableMetricsSecrets()
        )
        let clock = PortMetricsClock()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(),
            makeSampler: { FailingMetricsSampler() }, clock: clock.clock
        )
        defer { model.shutdown() }

        #expect(model.add(host))
        let server = try #require(model.servers.first)
        try await wait { server.collectionState == .failed && clock.delays.contains(2) }

        #expect(!server.needsAttention)
        #expect(server.authenticationPrompt == nil)
        #expect(model.snapshot(for: host.id)?.state == .failed)
    }

    @Test func credentialsContinueTheSameMonitorWithoutSavingAnIdentity() async throws {
        let host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        let hosts = HostLibraryModel(hosts: [host])
        let sampler = PortMetricsSampler()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(), makeSampler: { sampler })
        defer { model.shutdown() }
        #expect(model.add(host))
        let server = try #require(model.servers.first)
        try await wait { server.authenticationPrompt != nil }
        #expect(server.showsConnectionJourney)
        #expect(server.journey.purpose == .metrics)
        #expect(server.journey.localRequirement == .identity)
        let promptID = server.authenticationPrompt?.id
        #expect(server.authenticationPrompt?.id == promptID)
        model.observeDetails(hostID: host.id, observer: UUID())
        model.submitAuthentication(
            server, identityID: nil, username: "deploy", password: "test-only", passphrase: nil, keyID: nil, save: false
        )
        try await wait { server.hostKeyPrompt != nil }
        let observation = try #require(server.hostKey)
        model.acceptHostKey(server, observation: observation, remember: false)
        try await wait { server.point != nil }
        #expect(hosts.identities.isEmpty)
        #expect(hosts.knownHosts(for: host).isEmpty)
        #expect(model.servers.count == 1)
        #expect(await sampler.connections == 1)
        try await wait { server.processesDate != nil }
        #expect(await sampler.processRequests == 1)
        model.suspend()
        #expect(model.snapshot(for: host.id)?.state == .sleeping)
        model.remove(host.id)
        #expect(model.servers.isEmpty)
    }

    @Test func knownHostKeyConnectsWithoutRequestingConfirmation() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = TermindDomain.Host(
            name: "Monitor", host: "example.invalid", identityID: identity.id)
        let hosts = HostLibraryModel(
            hosts: [host], identities: [identity],
            knownHosts: [KnownHostEntry(hostname: host.host, fingerprint: "SHA256:test")]
        )
        try hosts.upsert(identity, passwordUpdate: .replace("test-only"))
        let sampler = PortMetricsSampler()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(), makeSampler: { sampler })
        defer { model.shutdown() }

        #expect(model.add(host))
        let server = try #require(model.servers.first)
        try await wait { server.point != nil }

        #expect(await sampler.hostKeyAuthorizationRequests == 1)
        #expect(await sampler.hostKeyChallenges == 0)
        #expect(server.hostKeyPrompt == nil)
        #expect(server.hostKey == nil)
        #expect(!server.needsAttention)
        #expect(server.collectionState == .live)
    }

    @Test func suspendingHostKeyConfirmationRequiresAFreshChallengeOnResume() async throws {
        let identity = Identity(name: "Deploy", username: "deploy")
        let host = TermindDomain.Host(name: "Monitor", host: "example.invalid", identityID: identity.id)
        let hosts = HostLibraryModel(hosts: [host], identities: [identity])
        try hosts.upsert(identity, passwordUpdate: .replace("test-only"))
        let sampler = PortMetricsSampler()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(), makeSampler: { sampler })
        defer { model.shutdown() }
        #expect(model.add(host))
        let server = try #require(model.servers.first)
        try await wait { server.hostKeyPrompt != nil }
        let observation = try #require(server.hostKey)
        model.suspend()
        #expect(server.hostKeyPrompt == nil && server.hostKey == nil && !server.needsAttention)
        model.acceptHostKey(server, observation: observation, remember: true)
        #expect(hosts.knownHosts(for: host).isEmpty)
        model.resume()
        try await wait { server.hostKeyPrompt != nil }
        #expect(await sampler.hostKeyChallenges == 2)
        model.acceptHostKey(server, observation: try #require(server.hostKey), remember: false)
        try await wait { server.point != nil }
        #expect(await sampler.connections == 1)
    }

    @Test func checkpointAndLogsSurviveAuthenticationContinuation() {
        let host = TermindDomain.Host(name: "Target", host: "example.invalid")
        let journey = ConnectionJourney()
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "deploy")
        journey.waitForHostKey(at: host.id, fingerprint: "SHA256:test")
        journey.resume()
        let logs = journey.logs
        journey.begin(host: host, route: [host], purpose: .sshSession, username: "deploy")
        #expect(journey.completedCheckpoints[1] == .hostKey)
        #expect(journey.logs.starts(with: logs))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }
}

@MainActor private final class PortMetricsPreferences: MetricsConfigurationStoring {
    private var selections: [MetricsSelection]
    init(selections: [MetricsSelection] = []) { self.selections = selections }
    func load() -> [MetricsSelection] { selections }
    func save(_ selections: [MetricsSelection]) { self.selections = selections }
}

private actor PortMetricsSampler: MetricsSampling {
    var connections = 0
    var hostKeyAuthorizationRequests = 0
    var hostKeyChallenges = 0
    var processRequests = 0
    func connect(_ configuration: SSHConnectionConfiguration) async throws { connections += 1 }
    func connect(_ request: SSHConnectionRequest) async throws {
        let configuration = request.configuration
        let observation = SSHHostKeyObservation(
            hostname: configuration.host, port: configuration.port,
            algorithm: .ed25519, fingerprint: "SHA256:test"
        )
        hostKeyAuthorizationRequests += 1
        if !configuration.expectedHostKeys.contains(observation.identity) {
            hostKeyChallenges += 1
        }
        guard let authorizeHostKey = request.authorizeHostKey else {
            throw TermindSSHError.untrustedHost
        }
        guard
            try await authorizeHostKey(
                SSHHostKeyChallenge(
                    hostID: configuration.hostID,
                    observation: observation,
                    expectedHostKeys: configuration.expectedHostKeys
                )
            ) == .accept
        else { throw CancellationError() }
        try await connect(configuration)
    }
    func sample() async throws -> MetricsSample {
        .init(uptime: 1, cpu: [10, 0, 10, 80], memoryUsed: 50, memoryTotal: 100)
    }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func processes() async throws -> MetricsProcessSample? {
        processRequests += 1
        return MetricsProcessSample(cpu: [10, 0, 10, 80], coreCount: 1, processes: [])
    }
    func disconnect() async {}
}

private actor FailingMetricsSampler: MetricsSampling {
    func connect(_ configuration: SSHConnectionConfiguration) async throws {
        throw TermindSSHError.socket("offline")
    }
    func sample() async throws -> MetricsSample { throw TermindSSHError.disconnected }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}

private enum UnavailableMetricsSecretError: Error {
    case locked
}

private struct UnavailableMetricsSecrets: SecretStoring {
    func string(for account: String, storage: PasswordStorage) throws -> String? {
        throw UnavailableMetricsSecretError.locked
    }

    func setString(_ value: String?, for account: String, storage: PasswordStorage) throws {}

    func keyCredential(
        for account: String, storage: KeyStorage
    ) throws -> StoredSSHKeyCredential? {
        throw UnavailableMetricsSecretError.locked
    }

    func setKeyCredential(
        _ value: StoredSSHKeyCredential?, for account: String, storage: KeyStorage
    ) throws {}

    func removePassword(_ account: String, storage: PasswordStorage) throws {}
    func removeKeyCredential(_ account: String, storage: KeyStorage) throws {}
}

private nonisolated final class BackgroundResumingMetricsSampler: MetricsSampling, @unchecked Sendable {
    private let lock = NSLock()
    private var connections = 0
    private var samples = 0

    func connect(_ configuration: SSHConnectionConfiguration) async throws {
        await resumeFromBackground()
        lock.withLock { connections += 1 }
    }

    func sample() async throws -> MetricsSample {
        await resumeFromBackground()
        lock.withLock { samples += 1 }
        return MetricsSample(uptime: 1, cpu: [10, 0, 10, 80], memoryUsed: 50, memoryTotal: 100)
    }

    func gpu() async throws -> NvidiaSnapshot? {
        await resumeFromBackground()
        return nil
    }

    func disconnect() async {}

    func snapshot() -> (connections: Int, samples: Int) {
        lock.withLock { (connections, samples) }
    }

    private func resumeFromBackground() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume()
            }
        }
    }
}

private nonisolated final class PortMetricsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)
    private var waiters: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    private var requested: [TimeInterval] = []

    var delays: [TimeInterval] { lock.withLock { requested } }
    var clock: MetricsClock {
        MetricsClock(
            now: { self.lock.withLock { self.date } },
            sleep: { try await self.sleep($0) })
    }

    func advance(_ seconds: TimeInterval) {
        let ready = lock.withLock {
            date.addTimeInterval(seconds)
            let ready = waiters.filter { $0.value.0 <= date }
            for id in ready.keys { waiters[id] = nil }
            return ready.values.map(\.1)
        }
        for waiter in ready { waiter.resume() }
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        requested.append(seconds)
                        waiters[id] = (date.addingTimeInterval(seconds), continuation)
                    }
                }
            }
        } onCancel: {
            let waiter = self.lock.withLock { self.waiters.removeValue(forKey: id)?.1 }
            waiter?.resume(throwing: CancellationError())
        }
    }
}

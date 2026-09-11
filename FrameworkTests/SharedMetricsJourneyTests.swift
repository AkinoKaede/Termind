import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite @MainActor
struct SharedMetricsJourneyTests {
    @Test func credentialsContinueTheSameMonitorWithoutSavingAnIdentity() async throws {
        let host = TermindDomain.Host(name: "Monitor", host: "example.invalid")
        let hosts = HostLibraryModel(hosts: [host])
        let sampler = PortMetricsSampler()
        let model = ServerMetricsModel(
            hosts: hosts, preferences: PortMetricsPreferences(), makeSampler: { sampler },
            discover: { host, _, _ in
                SSHHostKeyObservation(
                    hostname: host.host, port: host.port, algorithm: .ed25519, fingerprint: "SHA256:test")
            })
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
    func load() -> [MetricsSelection] { [] }
    func save(_ selections: [MetricsSelection]) {}
}

private actor PortMetricsSampler: MetricsSampling {
    var connections = 0
    var processRequests = 0
    func connect(_ configuration: SSHConnectionConfiguration) async throws { connections += 1 }
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

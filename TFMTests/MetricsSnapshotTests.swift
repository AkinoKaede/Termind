import Foundation
import TermindApplication
import TermindDomain
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite
@MainActor
struct MetricsSnapshotTests {
    @Test
    func readsCopyValuesWithoutCollectingOrSavingAndIgnoreDeletedHosts() throws {
        let host = Host(name: "Monitor", host: "monitor.example")
        let hosts = HostLibraryModel(hosts: [host])
        let preferences = SnapshotPreferences(hostID: host.id)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let model = ServerMetricsModel(
            hosts: hosts, preferences: preferences,
            makeSampler: { preconditionFailure("Snapshot reads cannot create samplers") },
            clock: MetricsClock(now: { now })
        )
        model.start()
        defer { model.shutdown() }
        let row = try #require(model.servers.first)
        row.point = MetricsPoint(date: now, cpu: 40)
        row.history = [try #require(row.point)]
        row.processes = [MetricsProcess(pid: 1, started: 1, name: "process", cpu: 125)]
        row.processesDate = now
        row.filesystemsDate = now
        let before = try #require(model.snapshot(for: host.id))
        #expect(before.state == .paused)
        #expect(before.capturedAt == now)
        #expect(before.processes.first?.cpu == 125)
        row.point?.cpu = 80
        row.history.removeAll()
        row.processes.removeAll()
        #expect(before.point?.cpu == 40)
        #expect(before.history.count == 1)
        #expect(before.processes.count == 1)
        #expect(model.snapshot(for: host.id)?.point?.cpu == 80)
        #expect(model.snapshot(for: UUID()) == nil)
        #expect(preferences.saves == 0)
        hosts.projectHostDeletion(host.id)
        #expect(model.snapshot(for: host.id) == nil)
    }

    @Test
    func lifecycleStateIsStructuredAndIndependentOfLocalizedText() async throws {
        let host = Host(name: "Monitor", host: "monitor.example")
        let model = ServerMetricsModel(
            hosts: HostLibraryModel(hosts: [host]), preferences: SnapshotPreferences(hostID: host.id),
            makeSampler: { preconditionFailure("Snapshot reads cannot create samplers") },
            clock: MetricsClock(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        )
        model.start()
        defer { model.shutdown() }
        let row = try #require(model.servers.first)
        row.selection.enabled = true
        row.status = "arbitrary translated display text"
        for state: MetricsMonitorState in [.connecting, .collecting, .live, .failed] {
            row.collectionState = state
            #expect(model.snapshot(for: host.id)?.state == state)
        }
        let observation = SSHHostKeyObservation(
            hostname: host.host, port: 22, algorithm: .ed25519, fingerprint: "SHA256:test")
        let authorization = Task {
            await row.hostKeyAuthorization.authorize(
                SSHHostKeyChallenge(hostID: host.id, observation: observation, expectedHostKeys: []))
        }
        for _ in 0..<100 where row.hostKey == nil { await Task.yield() }
        #expect(model.snapshot(for: host.id)?.state == .awaitingAuthentication)
        row.hostKeyAuthorization.reject()
        #expect(await authorization.value == .reject)
        model.suspend()
        #expect(model.snapshot(for: host.id)?.state == .sleeping)
        row.selection.enabled = false
        #expect(model.snapshot(for: host.id)?.state == .paused)
        model.resume()
        row.selection.enabled = true
        model.shutdown()
        #expect(model.snapshot(for: host.id)?.state == .stopped)
    }
}

@MainActor
private final class SnapshotPreferences: MetricsConfigurationStoring {
    let hostID: UUID
    var saves = 0
    init(hostID: UUID) { self.hostID = hostID }
    func load() -> [MetricsSelection] { [MetricsSelection(id: hostID, enabled: false)] }
    func save(_ selections: [MetricsSelection]) { saves += 1 }
}

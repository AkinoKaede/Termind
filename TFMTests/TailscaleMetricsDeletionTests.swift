import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@testable import Termind

@Suite @MainActor
struct TailscaleMetricsDeletionTests {
    @Test func deletingOrdinaryHostAlsoRemovesItsMetricsConfiguration() {
        let host = Host(name: "Ordinary", host: "example.invalid")
        let library = HostLibraryModel(hosts: [host])
        let preferences = DeletionMetricsPreferences([MetricsSelection(id: host.id, enabled: false)])
        let metrics = ServerMetricsModel(hosts: library, preferences: preferences, makeSampler: { DeletionSampler() })
        let app = AppModel(hosts: library, serverMetrics: metrics)
        metrics.start()
        defer { metrics.shutdown() }

        #expect(app.requestHostDeletion(host.id))
        #expect(library.host(host.id) == nil)
        #expect(metrics.selections.isEmpty)
        #expect(preferences.values.isEmpty)
    }

    @Test func deletingTailnetSubtreeRemovesUnseenMetricsEvenWhenKeepingManualHosts() throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        let child = HostGroup(name: "Child", parentID: group.id)
        let manual = Host(name: "Manual", host: "server", groupID: child.id)
        let library = HostLibraryModel(hosts: [manual], groups: [group, child])
        var unseen = MetricsSelection(id: network.hostID(stableNodeID: "n123"), enabled: false)
        unseen.tailscaleGroupID = group.id
        unseen.displayName = "Unseen"
        let preferences = DeletionMetricsPreferences([unseen, MetricsSelection(id: manual.id, enabled: false)])
        let metrics = ServerMetricsModel(hosts: library, preferences: preferences, makeSampler: { DeletionSampler() })
        let app = AppModel(hosts: library, serverMetrics: metrics)
        metrics.start()
        defer { metrics.shutdown() }

        app.deleteHostGroup(group.id, keepHosts: true)

        #expect(library.host(manual.id) != nil)
        #expect(library.host(manual.id)?.groupID == nil)
        #expect(metrics.selections.map(\.id) == [manual.id])
    }
}

@MainActor private final class DeletionMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection]
    init(_ values: [MetricsSelection]) { self.values = values }
    func load() throws -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws { values = selections }
}

private nonisolated struct DeletionSampler: MetricsSampling {
    func connect(_ configuration: SSHConnectionConfiguration) async throws { throw CancellationError() }
    func sample() async throws -> MetricsSample { throw CancellationError() }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}

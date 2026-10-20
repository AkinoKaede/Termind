// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import TermindDomain
import Testing

import struct TermindDomain.Host

@Suite @MainActor
struct TailscaleMetricsAvailabilityTests {
    @Test(arguments: [false, true])
    func missingPeerHidesCardWithoutChangingConfigurationAndReturnsInOrder(enabled: Bool) async throws {
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var group = HostGroup(name: "Tailnet")
        group.tailscale = TailscaleGroupConfiguration(network: network)
        group.tailscale?.username = "operator"
        let hostID = try #require(group.tailscale).hostID(groupID: group.id, stableNodeID: "n123")
        let other = Host(name: "Other", host: "other.invalid")
        let library = HostLibraryModel(hosts: [other], groups: [group])
        let provider = AvailabilityProvider()
        library.tailscaleConnections = provider
        var selection = MetricsSelection(id: hostID, enabled: enabled, disks: ["sda"], interfaces: [])
        selection.tailscaleGroupID = group.id
        selection.displayName = "Saved name"
        let otherSelection = MetricsSelection(id: other.id, enabled: false)
        let preferences = AvailabilityPreferences([selection, otherSelection])
        let sampler = AvailabilitySampler()
        let model = ServerMetricsModel(hosts: library, preferences: preferences, makeSampler: { sampler })
        model.start()
        defer { model.shutdown() }
        #expect(model.servers.map(\.id) == [other.id])
        #expect(model.selections == [selection, otherSelection])
        #expect(await sampler.connections == 0)

        var peer = TailscalePeer(
            stableID: "n123", name: "Server", dnsName: "server.example.ts.net", online: true,
            sshHostKeys: ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"])
        library.replaceTailscalePeers([peer], groupID: group.id)
        model.reconcile()
        #expect(model.servers.map(\.id) == [hostID, other.id])
        if enabled {
            try await settle { model.snapshot(for: hostID)?.state == .live }
            #expect(await sampler.connections == 1)
        } else {
            #expect(model.snapshot(for: hostID)?.state == .paused)
        }

        library.replaceTailscalePeers([], groupID: group.id)
        model.reconcile()
        #expect(model.servers.map(\.id) == [other.id])
        #expect(model.snapshot(for: hostID) == nil)
        #expect(!model.keepsRunning)
        #expect(preferences.values == [selection, otherSelection])
        #expect(preferences.saves == 0)
        if enabled { try await settle { await sampler.disconnections > 0 } }
        #expect(model.replaceHosts(selectedIDs: [other.id], editableHostIDs: [other.id]))
        #expect(model.selections == [selection, otherSelection])

        peer.name = "Renamed server"
        peer.online = false
        library.replaceTailscalePeers([peer], groupID: group.id)
        model.reconcile()
        #expect(model.servers.map(\.id) == [hostID, other.id])
        #expect(model.servers.first?.name == peer.name)
        #expect(model.servers.first?.selection == selection)
        #expect(preferences.saves == 0)
        if enabled {
            try await settle { model.snapshot(for: hostID)?.state == .live }
            #expect(await sampler.connections == 2)
        } else {
            #expect(model.snapshot(for: hostID)?.state == .paused)
            #expect(await sampler.connections == 0)
        }

        library.replaceTailscalePeers([], groupID: group.id)
        model.reconcile()
        model.removeTailscaleGroups([group.id])
        #expect(model.selections == [otherSelection])
        #expect(preferences.values == [otherSelection])
    }

    private func settle(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }
}

@MainActor private final class AvailabilityPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection]
    var saves = 0
    init(_ values: [MetricsSelection]) { self.values = values }
    func load() throws -> [MetricsSelection] { values }
    func save(_ values: [MetricsSelection]) throws {
        self.values = values
        saves += 1
    }
}

private actor AvailabilitySampler: MetricsSampling {
    var connections = 0
    var disconnections = 0
    func connect(_ configuration: SSHConnectionConfiguration) async throws { connections += 1 }
    func sample() async throws -> MetricsSample { MetricsSample(uptime: 1, cpu: [1, 1, 1, 1], coreCount: 1) }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async { disconnections += 1 }
}

@MainActor private final class AvailabilityProvider: TailscaleConnectionProviding {
    func connection(for groupID: UUID) throws -> any SSHNetworkDialing { AvailabilityDialer() }
}

private nonisolated struct AvailabilityDialer: SSHNetworkDialing {
    func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { throw CancellationError() }
    func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
}

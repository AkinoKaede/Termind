import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct TailscaleSyncSafetyTests {
    @Test(arguments: [TailscaleGroupConfiguration.HostIdentityVersion.legacy, .groupScoped])
    func v3UpgradeRefetchesAndAcceptsIndependentConnectionsToTheSameTailnet(
        firstIdentity: TailscaleGroupConfiguration.HostIdentityVersion
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let persistence = HostPersistence(context: fixture.container.mainContext)
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var first = HostGroup(name: "First")
        first.tailscale = TailscaleGroupConfiguration(network: network, hostIdentityVersion: firstIdentity)
        _ = try persistence.save(.init(groups: [first]))
        var second = HostGroup(name: "Second")
        second.tailscale = TailscaleGroupConfiguration(network: network)
        second.tailscale?.username = "other-account"
        let record = try groupRecord(second, zone: fixture.lifecycle.zoneID)
        let safety = try fixture.safety()
        let scope = try #require(fixture.lifecycle.scope)
        #expect(try !fixture.lifecycle.store.safety.prepare(scope))
        try safety.quarantine(
            recordName: record.recordID.recordName,
            payloadData: CloudSyncRecordCoding.payloadData(
                from: record, invalidEnvelope: CocoaError(.coderReadCorrupt)),
            reason: "Old client", reasonCode: .unsupportedFormat)
        #expect(fixture.batch([.saveRecord(record.recordID), .deleteRecord(record.recordID)]) == nil)
        var oldFormats = SyncRecordFormats.vault.formats
        oldFormats["hostGroup"] = .init(readingVersions: [1, 2], writingVersion: 2)
        try safety.capability().capabilityID = SyncRecordFormats(oldFormats).capabilityID
        try safety.recovery().requiresRefetch = false
        try fixture.container.mainContext.save()
        fixture.stop()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = { try fixture.receive([record], []) }
        try await fixture.start()
        #expect(fixture.network.serializations.last! == nil)
        let groups = try persistence.load().groups
        #expect(Set(groups.map(\.id)) == [first.id, second.id])
        #expect(groups.first { $0.id == second.id }?.tailscale?.username == "other-account")
        #expect(try !safety.isUploadBlocked(recordName: record.recordID.recordName))
        #expect(try safety.capability().capabilityID == SyncRecordFormats.vault.capabilityID)
    }

    @Test func conflictingTailnetDoesNotBlockOtherRecordsAndRefetchesAfterUnbinding() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let persistence = HostPersistence(context: fixture.container.mainContext)
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var local = HostGroup(name: "Local")
        local.tailscale = TailscaleGroupConfiguration(network: network, hostIdentityVersion: .legacy)
        _ = try persistence.save(VaultSnapshot(groups: [local]))
        var remote = HostGroup(name: "Remote")
        remote.tailscale = TailscaleGroupConfiguration(network: network, hostIdentityVersion: .legacy)
        remote.tailscale?.username = "preserved-user"
        remote.isExpanded = false
        let unrelated = HostGroup(name: "Unrelated")
        let record = try groupRecord(remote, zone: fixture.lifecycle.zoneID)
        let ordinary = try groupRecord(unrelated, zone: fixture.lifecycle.zoneID)
        for _ in 0..<2 { try fixture.receive([record, ordinary], []) }
        let snapshot = try persistence.load()
        #expect(Set(snapshot.groups.map(\.id)) == [local.id, unrelated.id])
        let safety = try fixture.safety()
        let isolated = try #require(try safety.entry(recordName: record.recordID.recordName))
        #expect(isolated.reasonCode == CloudSyncQuarantineReason.duplicateTailscaleNetwork.rawValue)
        #expect(try VaultSyncCodec.decode(isolated.payloadData).payload == .hostGroup(remote))
        #expect(fixture.record(record.recordID) == nil)
        #expect(fixture.batch([.saveRecord(record.recordID), .deleteRecord(record.recordID)]) == nil)

        local.tailscale = nil
        _ = try persistence.save(VaultSnapshot(groups: [local, unrelated]))
        fixture.stop()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = { try fixture.receive([record, ordinary], []) }
        try await fixture.start()
        #expect(fixture.network.serializations.last! == nil)
        #expect(try persistence.load().groups.first { $0.id == remote.id }?.tailscale?.username == "preserved-user")
        #expect(try !safety.isUploadBlocked(recordName: record.recordID.recordName))
    }

    @Test func sameBatchDeletionReleasesTailnetOwnership() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let persistence = HostPersistence(context: fixture.container.mainContext)
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var local = HostGroup(name: "Local")
        local.tailscale = TailscaleGroupConfiguration(network: network, hostIdentityVersion: .legacy)
        _ = try persistence.save(VaultSnapshot(groups: [local]))
        var remote = HostGroup(name: "Remote")
        remote.tailscale = local.tailscale
        let record = try groupRecord(remote, zone: fixture.lifecycle.zoneID)
        let deletedID = CKRecord.ID(
            recordName: VaultRecordKey(kind: .hostGroup, id: local.id).recordName, zoneID: fixture.lifecycle.zoneID)
        try fixture.receive([record], [deletedID])
        #expect(try persistence.load().groups == [remote])
        #expect(try fixture.safety().blockedRecordNames().isEmpty)
    }

    @Test func metricsUpgradeRefetchesAndUnblocksPreviouslyUnsupportedSelections() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .metrics)
        defer { fixture.stop() }
        try await fixture.start()
        let safety = try fixture.safety()
        let record = try fixture.newerRecord(fixture.recordIDs[0])
        let scope = try #require(fixture.lifecycle.scope)
        #expect(try !fixture.lifecycle.store.safety.prepare(scope))
        try safety.quarantine(
            recordName: record.recordID.recordName,
            payloadData: CloudSyncRecordCoding.payloadData(
                from: record, invalidEnvelope: CocoaError(.coderReadCorrupt)),
            reason: "Old client", reasonCode: .unsupportedFormat)
        try safety.capability().capabilityID = "selection:1"
        try safety.recovery().requiresRefetch = false
        #expect(try fixture.lifecycle.store.safety.prepare(scope))
        try fixture.container.mainContext.save()
        fixture.stop()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = { try fixture.receive([record], []) }
        try await fixture.start()
        #expect(fixture.network.serializations.last! == nil)
        #expect(try safety.capability().capabilityID == SyncRecordFormats.metrics.capabilityID)
        #expect(try !safety.isUploadBlocked(recordName: record.recordID.recordName))
        let journal = MetricsSyncJournal(context: fixture.container.mainContext)
        #expect(
            try journal.envelope(for: MetricsRecordKey(recordName: record.recordID.recordName)!)
                == MetricsSyncCoordinator.envelope(from: record))
    }

    @Test(arguments: [false, true])
    func conflictRecoveryUsesCoordinatorRetryOrLocalGroupMutation(retry: Bool) async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let name = "TailscaleSyncSafetyTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: SettingsKey.iCloudSyncEnabled)
        let network = LifecycleNetwork()
        let coordinator = VaultSyncCoordinator(
            context: container.mainContext, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in network.transport })
        defer { coordinator.pause() }
        coordinator.start()
        await coordinator.lifecycle.operation?.value
        let scope = try #require(coordinator.lifecycle.scope)
        #expect(try !coordinator.lifecycle.store.safety.prepare(scope))
        let persistence = HostPersistence(context: container.mainContext)
        var local = HostGroup(name: "Local")
        local.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net"),
            hostIdentityVersion: .legacy)
        _ = try persistence.save(VaultSnapshot(groups: [local]))
        var remote = HostGroup(name: "Remote")
        remote.tailscale = local.tailscale
        let record = try groupRecord(remote, zone: coordinator.lifecycle.zoneID)
        try coordinator.receiveRemoteRecords([record])
        let safety = CloudSyncSafetyStore(context: container.mainContext, scope: scope)
        #expect(try coordinator.lifecycle.store.safety.prepare(scope))
        var otherScope = scope
        otherScope.account = "other-account"
        #expect(
            try !CloudSyncSafetyStore(context: container.mainContext, scope: otherScope)
                .hasQuarantine(reason: .duplicateTailscaleNetwork))
        local.tailscale = nil
        let mutations = try persistence.save(VaultSnapshot(groups: [local]))
        let previousEngine = network.nextEngine
        network.nextEngine = LifecycleEngine()
        network.nextEngine.fetchBody = {
            #expect(!coordinator.lifecycle.isReadyToSend)
            try coordinator.receiveRemoteRecords([record])
        }
        if retry { coordinator.retry() } else { coordinator.noteLocalChanges(mutations) }
        await coordinator.lifecycle.operation?.value
        for _ in 0..<100 where previousEngine.cancelCount == 0 { await Task.yield() }
        #expect(previousEngine.cancelCount == 1)
        #expect(network.engineCount == 2)
        #expect(network.nextEngine.fetchCount == 1)
        #expect(try !safety.isUploadBlocked(recordName: record.recordID.recordName))
        #expect(try !coordinator.lifecycle.store.safety.prepare(scope))
    }

    @Test func fullRefetchRemovesAnIsolatedGroupDeletedFromTheCloud() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let persistence = HostPersistence(context: fixture.container.mainContext)
        var local = HostGroup(name: "Local")
        local.tailscale = TailscaleGroupConfiguration(
            network: try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net"),
            hostIdentityVersion: .legacy)
        _ = try persistence.save(VaultSnapshot(groups: [local]))
        var remote = HostGroup(name: "Remote")
        remote.tailscale = local.tailscale
        let record = try groupRecord(remote, zone: fixture.lifecycle.zoneID)
        try fixture.receive([record], [])
        #expect(try fixture.safety().isUploadBlocked(recordName: record.recordID.recordName))
        fixture.stop()
        fixture.network.nextEngine = LifecycleEngine()
        try await fixture.start()
        #expect(try !fixture.safety().isUploadBlocked(recordName: record.recordID.recordName))
        #expect(try persistence.load().groups.map(\.id) == [local.id])
        #expect(
            try VaultSyncJournal(context: fixture.container.mainContext)
                .envelope(for: VaultRecordKey(kind: .hostGroup, id: remote.id))?.isDeleted == true)
    }

    private func groupRecord(_ group: HostGroup, zone: CKRecordZone.ID) throws -> CKRecord {
        let payload = VaultRecordPayload.hostGroup(group)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        return try VaultSyncCoordinator.makeRecord(
            .init(envelope: envelope), recordID: .init(recordName: payload.key.recordName, zoneID: zone))
    }
}

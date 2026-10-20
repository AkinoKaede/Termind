// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    @Test func v3ReplayAcceptsIndependentConnectionsToTheSameTailnet() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let persistence = HostPersistence(context: fixture.container.mainContext)
        let network = try TailscaleNetwork(controlURL: TailscaleNetwork.defaultControlURL, dnsSuffix: "example.ts.net")
        var first = HostGroup(name: "First")
        first.tailscale = TailscaleGroupConfiguration(network: network)
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
        #expect(try safety.capability().capabilityID == MetricsSyncCodec.capabilityID)
        #expect(try !safety.isUploadBlocked(recordName: record.recordID.recordName))
        let journal = MetricsSyncJournal(context: fixture.container.mainContext)
        #expect(
            try journal.envelope(for: MetricsRecordKey(recordName: record.recordID.recordName)!)
                == MetricsSyncCoordinator.envelope(from: record))
    }

    private func groupRecord(_ group: HostGroup, zone: CKRecordZone.ID) throws -> CKRecord {
        let payload = VaultRecordPayload.hostGroup(group)
        let envelope = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        return try VaultSyncCoordinator.makeRecord(
            .init(envelope: envelope), recordID: .init(recordName: payload.key.recordName, zoneID: zone))
    }
}

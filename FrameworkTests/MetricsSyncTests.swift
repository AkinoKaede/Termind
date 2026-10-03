import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct MetricsSyncTests {
    @Test(arguments: [false, true])
    func historicalV1CloudRecordsRemainReadable(isDeleted: Bool) throws {
        let record = try historicalRecord(isDeleted: isDeleted)
        let envelope = try MetricsSyncCoordinator.envelope(from: record)
        #expect(envelope.formatVersion == 1)
        #expect(envelope.isDeleted == isDeleted)
        if !isDeleted {
            guard case .selection(let value) = envelope.payload else {
                Issue.record("Historical Metrics selection was lost")
                return
            }
            #expect(!value.selection.enabled)
            #expect(value.selection.disks == ["sda"])
            #expect(value.selection.interfaces == [])
            #expect(value.selection.tailscaleGroupID == nil)
        }
    }

    @Test
    func readerUpgradeRefetchesQuarantinedV1WithoutLosingPendingLocalEdits() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .metrics, seed: false)
        defer { fixture.stop() }
        try await fixture.start()
        let record = try historicalRecord()
        let old = try MetricsSyncCodec.decode(
            CloudSyncRecordCoding.payloadData(from: record, invalidEnvelope: CocoaError(.coderReadCorrupt)))
        let persistence = MetricsSyncPersistence(context: fixture.container.mainContext, defaults: fixture.defaults)
        try persistence.save([MetricsSelection(id: old.key.id, interfaces: ["en0"])])
        let journal = persistence.journal
        let local = try #require(try journal.envelope(for: old.key))
        let safety = try fixture.safety()
        try safety.quarantine(
            recordName: record.recordID.recordName,
            payloadData: CloudSyncRecordCoding.payloadData(
                from: record, invalidEnvelope: CocoaError(.coderReadCorrupt)),
            reason: "Previous reader rejected V1", reasonCode: .invalidRecord)
        try safety.capability().capabilityID = SyncRecordFormats.metrics.capabilityID
        try safety.recovery().requiresRefetch = false
        try fixture.container.mainContext.save()
        #expect(fixture.batch([.saveRecord(record.recordID)]) == nil)

        fixture.stop()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = { try fixture.receive([record], []) }
        try await fixture.start()

        #expect(fixture.network.serializations.last! == nil)
        #expect(try safety.blockedRecordNames().isEmpty)
        #expect(try safety.capability().capabilityID == MetricsSyncCodec.capabilityID)
        #expect(try journal.envelope(for: old.key) == local)
        let batch = try #require(fixture.batch([.saveRecord(record.recordID)]))
        #expect(try MetricsSyncCoordinator.envelope(from: #require(batch.recordsToSave.first)) == local)
    }

    @Test
    func legacySelectionsMigrateOnceWithCompleteConfigurationAndOrder() throws {
        let defaults = UserDefaults(suiteName: "MetricsSyncTests.\(UUID())")!
        let first = MetricsSelection(id: UUID(), enabled: false, disks: ["sda"], interfaces: [])
        let second = MetricsSelection(id: UUID(), interfaces: ["eth0"])
        defaults.set(try JSONEncoder().encode([first]), forKey: "metrics.servers")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "mobile.metrics.v1")
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let store = MetricsSyncPersistence(context: container.mainContext, defaults: defaults)

        try store.prepare()

        #expect(try store.load() == [first, second])
        #expect(try store.journal.pendingEnvelopes().count == 2)
        defaults.set(try JSONEncoder().encode([] as [MetricsSelection]), forKey: "metrics.servers")
        try store.prepare()
        #expect(try store.load() == [first, second])
    }

    @Test
    func recordsRoundTripAndRemoteChangesMergePerHost() throws {
        let (sourceContainer, source) = try fixture()
        let (destinationContainer, destination) = try fixture()
        defer { withExtendedLifetime((sourceContainer, destinationContainer)) {} }
        let first = MetricsSelection(id: UUID(), enabled: false, disks: ["nvme0n1"])
        let second = MetricsSelection(id: UUID(), interfaces: ["en0"])
        try source.save([first, second])

        let outgoing = try source.journal.pendingEnvelopes()
        let applied = try destination.applyRemote(outgoing)
        #expect(applied.snapshot.selections == [first, second])

        let envelope = try #require(outgoing.first)
        let data = try MetricsSyncCodec.encode(envelope)
        #expect(try MetricsSyncCodec.decode(data) == envelope)
        let record = try MetricsSyncCoordinator.makeRecord(
            MetricsOutgoingEntry(envelope: envelope),
            recordID: CKRecord.ID(
                recordName: envelope.key.recordName,
                zoneID: CKRecordZone.ID(zoneName: MetricsSyncCoordinator.zoneName)))
        #expect(try MetricsSyncCoordinator.envelope(from: record) == envelope)

        try source.save([second, first])
        let reordered = try destination.applyRemote(source.journal.pendingEnvelopes())
        #expect(reordered.snapshot.selections == [second, first])

        try source.save([second])
        let deleted = try destination.applyRemote(source.journal.pendingEnvelopes())
        #expect(deleted.snapshot.selections == [second])
    }

    @Test
    func missingHostsStayConfiguredAndMaterializeLater() {
        let host = TermindDomain.Host(name: "Later", host: "example.invalid")
        let preferences = TestMetricsPreferences(values: [MetricsSelection(id: host.id, enabled: false)])
        let library = HostLibraryModel()
        let model = ServerMetricsModel(
            hosts: library, preferences: preferences,
            makeSampler: { TestMetricsSampler() })

        model.start()
        model.suspend()
        #expect(model.servers.isEmpty)
        #expect(model.selections.map(\.id) == [host.id])

        library.upsert(host)
        model.reconcile()
        #expect(model.servers.map(\.id) == [host.id])
        #expect(!model.servers[0].selection.enabled)
    }

    @Test
    func failedPersistenceDoesNotChangeRuntimeConfiguration() {
        let host = TermindDomain.Host(name: "Stable", host: "example.invalid")
        let preferences = TestMetricsPreferences(values: [MetricsSelection(id: host.id)])
        let library = HostLibraryModel()
        library.upsert(host)
        let model = ServerMetricsModel(
            hosts: library, preferences: preferences,
            makeSampler: { TestMetricsSampler() })
        model.start()
        model.suspend()
        preferences.failSaves = true

        model.setEnabled(false, for: model.servers[0])

        #expect(model.servers[0].selection.enabled)
        #expect(model.storageError == TestMetricsError.failed.localizedDescription)
    }

    @Test
    func metricsCategoryDefaultsOnWithoutChangingTheMasterPreference() {
        let defaults = UserDefaults(suiteName: "MetricsSyncDefaults.\(UUID())")!
        defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: defaults)
        #expect(SettingsKey.defaultMetricsSyncEnabled)
        #expect(!defaults.bool(forKey: SettingsKey.iCloudSyncEnabled))
        #expect(defaults.object(forKey: SettingsKey.metricsSyncEnabled) == nil)
    }

    private func fixture() throws -> (ModelContainer, MetricsSyncPersistence) {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let defaults = UserDefaults(suiteName: "MetricsSyncFixture.\(UUID())")!
        let store = MetricsSyncPersistence(context: container.mainContext, defaults: defaults)
        try store.prepare()
        return (container, store)
    }

    private func historicalRecord(isDeleted: Bool = false) throws -> CKRecord {
        let id = "30000000-0000-0000-0000-000000000001"
        let payload =
            isDeleted
            ? ""
            : """
            ,"payload":{"selection":{"_0":{"selection":{
            "id":"\(id)","enabled":false,"disks":["sda"],"interfaces":[]},"sortIndex":0}}}
            """
        let data = Data(
            """
            {"formatVersion":1,"key":{"kind":"selection","id":"\(id)"},
            "version":{"modifiedAt":100,"counter":1,"writerID":"11111111-1111-1111-1111-111111111111"},
            "isDeleted":\(isDeleted)\(payload)}
            """.utf8)
        let record = CKRecord(
            recordType: MetricsSyncCoordinator.recordType,
            recordID: CKRecord.ID(
                recordName: "v1/selection/\(id)",
                zoneID: CKRecordZone.ID(zoneName: MetricsSyncCoordinator.zoneName)))
        try CloudSyncRecordCoding.setPayload(data, on: record, assetURL: FileManager.default.temporaryDirectory)
        return record
    }
}

private enum TestMetricsError: LocalizedError {
    case failed
    var errorDescription: String? { "Metrics persistence failed." }
}

@MainActor
private final class TestMetricsPreferences: MetricsConfigurationStoring {
    var values: [MetricsSelection]
    var failSaves = false

    init(values: [MetricsSelection]) { self.values = values }
    func load() -> [MetricsSelection] { values }
    func save(_ selections: [MetricsSelection]) throws {
        if failSaves { throw TestMetricsError.failed }
        values = selections
    }
}

nonisolated private struct TestMetricsSampler: MetricsSampling {
    func connect(_ configuration: SSHConnectionConfiguration) async throws {}
    func sample() async throws -> MetricsSample { throw CancellationError() }
    func gpu() async throws -> NvidiaSnapshot? { nil }
    func disconnect() async {}
}

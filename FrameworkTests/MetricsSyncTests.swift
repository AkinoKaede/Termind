import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct MetricsSyncTests {
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

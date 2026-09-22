import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncSafetyPersistenceTests {
    private var scope: CloudSyncScope {
        CloudSyncScope(
            container: "iCloud.test", environment: "Production", account: "first-account",
            zone: "TestZone", owner: "owner")
    }

    @Test
    func blocksAndRecoveryAreScopedByContainerEnvironmentAccountZoneAndOwner() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let original = CloudSyncSafetyStore(context: context, scope: scope)
        try original.quarantine(recordName: "same-record", payloadData: Data([1]), reason: "unsupported")
        try original.recovery().requiresRefetch = false
        try context.save()
        var otherScopes: [CloudSyncScope] = []
        var changed = scope
        changed.container = "iCloud.other"
        otherScopes.append(changed)
        changed = scope
        changed.environment = "Development"
        otherScopes.append(changed)
        changed = scope
        changed.account = "second-account"
        otherScopes.append(changed)
        changed = scope
        changed.zone = "OtherZone"
        otherScopes.append(changed)
        changed = scope
        changed.owner = "other-owner"
        otherScopes.append(changed)
        for otherScope in otherScopes {
            let other = CloudSyncSafetyStore(context: context, scope: otherScope)
            #expect(try other.blockedRecordNames().isEmpty)
            #expect(try other.recovery().requiresRefetch)
            try other.quarantine(recordName: "same-record", payloadData: Data([2]), reason: "different")
            try context.save()
            try other.clearQuarantine(recordName: "same-record")
            try context.save()
            #expect(try original.isUploadBlocked(recordName: "same-record"))
            #expect(try !original.recovery().requiresRefetch)
            #expect(try original.entry(recordName: "same-record")?.payloadData == Data([1]))
        }
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func fileStoreReopenRetainsQuarantineRecoveryFenceAndLocalPendingIntent(category: SyncSafetyCategory) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Safety.store")
        let saved = try await writeInterruptedFetch(category: category, to: url)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let context = reopened.mainContext
        let safety = CloudSyncSafetyStore(context: context, scope: saved.scope)
        #expect(try safety.recovery().requiresRefetch)
        #expect(try safety.entry(recordName: saved.recordName)?.payloadData == saved.data)
        let pending: [String]
        let uploadable: [String]
        switch category {
        case .vault:
            let journal = VaultSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try journal.uploadablePendingRecordNames(in: saved.scope)
            let key = try #require(VaultRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        case .settings:
            let journal = SettingsSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try journal.uploadablePendingRecordNames(in: saved.scope)
            let key = try #require(SettingsRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        case .metrics:
            let journal = MetricsSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try journal.uploadablePendingRecordNames(in: saved.scope)
            let key = try #require(MetricsRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        }
        #expect(pending.contains(saved.recordName))
        #expect(!uploadable.contains(saved.recordName))
        #expect(uploadable.count == 1)
    }

    @Test
    func version30StoreMigratesAdditivelyAndLegacyQuarantineIsArchivedUnderItsOriginalScope() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Legacy.store")
        try writeVersion30(to: url)
        let container = try TermindPersistence.makeContainer(url: url)
        let context = container.mainContext
        let vault = VaultSyncJournal(context: context)
        let settings = SettingsSyncJournal(context: context)
        let metrics = MetricsSyncJournal(context: context)
        try context.commit {
            try vault.importLegacyQuarantine(into: scope)
            try settings.importLegacyQuarantine(into: scope)
            try metrics.importLegacyQuarantine(into: scope)
        }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        #expect(try safety.blockedRecordNames() == ["vault-legacy", "settings-legacy", "metrics-legacy"])
        #expect(try safety.entry(recordName: "vault-legacy")?.payloadData == Data([3, 0]))
        #expect(try safety.recovery().requiresRefetch)
        #expect(try context.fetchCount(FetchDescriptor<PersistentVaultSyncQuarantine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PersistentAIConfigurationSyncQuarantine>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PersistentMetricsSyncQuarantine>()) == 0)
        #expect(try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name) == ["Existing data"])
        #expect(!TermindSchemaV30.models.contains { $0 == PersistentCloudSyncQuarantine.self })
        #expect(TermindSchemaV31.models.contains { $0 == PersistentCloudSyncQuarantine.self })
        #expect(TermindMigrationPlan.schemas.last?.versionIdentifier == TermindSchemaV31.versionIdentifier)
    }

    private func writeInterruptedFetch(
        category: SyncSafetyCategory, to url: URL
    ) async throws -> (scope: CloudSyncScope, recordName: String, data: Data) {
        let fixture = try CloudSyncSafetyFixture(category: category, url: url)
        defer { fixture.stop() }
        try await fixture.start()
        let record = try fixture.futureRecord()
        try fixture.lifecycle.beginFetch()
        try fixture.receive([record], [])
        // Simulate termination before didFetchChanges: the durable fence must remain set.
        return (
            try #require(fixture.lifecycle.scope), record.recordID.recordName,
            try #require(record["payload"] as? Data)
        )
    }

    private func writeVersion30(to url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV30.self)
        let configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.insert(PersistentHostGroup(HostGroup(name: "Existing data")))
        try VaultSyncJournal(context: context).quarantine(
            recordName: "vault-legacy", payloadData: Data([3, 0]), reason: "legacy error")
        try SettingsSyncJournal(context: context).quarantine(
            recordName: "settings-legacy", payloadData: Data([3, 0]), reason: "legacy error")
        try MetricsSyncJournal(context: context).quarantine(
            recordName: "metrics-legacy", payloadData: Data([3, 0]), reason: "legacy error")
        try context.save()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

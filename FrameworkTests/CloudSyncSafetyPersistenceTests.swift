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

    @Test(arguments: SyncSafetyCategory.allCases)
    func journalUploadAcknowledgementAndSystemFieldsSkipNoOpWrites(category: SyncSafetyCategory) throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let version = VaultVersion(
            modifiedAt: Date(timeIntervalSince1970: 100), counter: 1,
            writerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let testScope = scope
        let updateSystemFields: (Data?) throws -> Void
        let markUploaded: () throws -> Void
        let markNeedsUpload: () throws -> Void
        let hasOutgoingEntry: () throws -> Bool

        switch category {
        case .history, .device:
            let payload: HistoryRecordPayload =
                category == .device
                ? .device(DeviceRecord(id: UUID(), displayName: "Device"))
                : .connectionHistory(ConnectionHistoryEntry(hostID: UUID(), kind: .ssh))
            let envelope = HistoryEnvelope(key: payload.key, version: version, payload: payload)
            let journal = HistorySyncJournal(context: context, kind: envelope.key.kind)
            try journal.store(envelope, needsUpload: true)
            updateSystemFields = { try journal.updateSystemFields($0, for: envelope.key) }
            markUploaded = { try journal.markUploaded(envelope.key, version: version) }
            markNeedsUpload = { try journal.markNeedsUpload([envelope.key]) }
            hasOutgoingEntry = { try journal.outgoingEntry(for: envelope.key, scope: testScope) != nil }
        case .vault:
            let payload = VaultRecordPayload.hostGroup(HostGroup(name: "Group"))
            let envelope = VaultEnvelope(key: payload.key, version: version, payload: payload)
            let journal = VaultSyncJournal(context: context)
            try journal.acceptRemote([envelope])
            try journal.markNeedsUpload([envelope.key])
            updateSystemFields = { try journal.updateSystemFields($0, for: envelope.key) }
            markUploaded = { try journal.markUploaded(envelope.key, version: version) }
            markNeedsUpload = { try journal.markNeedsUpload([envelope.key]) }
            hasOutgoingEntry = { try journal.outgoingEntry(for: envelope.key, scope: testScope) != nil }
        case .settings:
            let payload = SettingsRecordPayload.sftp(SFTPPreferences())
            let envelope = SettingsEnvelope(key: payload.key, version: version, payload: payload)
            let journal = SettingsSyncJournal(context: context)
            try journal.acceptRemote([envelope])
            try journal.markNeedsUpload([envelope.key])
            updateSystemFields = { try journal.updateSystemFields($0, for: envelope.key) }
            markUploaded = { try journal.markUploaded(envelope.key, version: version) }
            markNeedsUpload = { try journal.markNeedsUpload([envelope.key]) }
            hasOutgoingEntry = { try journal.outgoingEntry(for: envelope.key, scope: testScope) != nil }
        case .metrics:
            let payload = MetricsRecordPayload.selection(
                SyncedMetricsSelection(selection: MetricsSelection(id: UUID()), sortIndex: 0))
            let envelope = MetricsEnvelope(key: payload.key, version: version, payload: payload)
            let journal = MetricsSyncJournal(context: context)
            try journal.acceptRemote([envelope])
            try journal.markNeedsUpload([envelope.key])
            updateSystemFields = { try journal.updateSystemFields($0, for: envelope.key) }
            markUploaded = { try journal.markUploaded(envelope.key, version: version) }
            markNeedsUpload = { try journal.markNeedsUpload([envelope.key]) }
            hasOutgoingEntry = { try journal.outgoingEntry(for: envelope.key, scope: testScope) != nil }
        }
        try context.save()
        #expect(try hasOutgoingEntry())

        try updateSystemFields(nil)
        #expect(!context.hasChanges)
        try updateSystemFields(Data([1, 2, 3]))
        #expect(context.hasChanges)
        try context.save()
        try updateSystemFields(Data([1, 2, 3]))
        #expect(!context.hasChanges)
        try updateSystemFields(nil)
        #expect(context.hasChanges)
        try context.save()
        try updateSystemFields(nil)
        #expect(!context.hasChanges)

        try markUploaded()
        #expect(context.hasChanges)
        try context.save()
        #expect(try !hasOutgoingEntry())
        try markUploaded()
        #expect(!context.hasChanges)
        try markNeedsUpload()
        #expect(context.hasChanges)
        try context.save()
        #expect(try hasOutgoingEntry())
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
        case .history, .device:
            let journal = HistorySyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try CloudSyncRecordStateStore(context: context, scope: saved.scope)
                .pendingChanges(journal.cloudRecords()).map(\.recordName)
            let key = try #require(HistoryRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        case .vault:
            let journal = VaultSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try CloudSyncRecordStateStore(context: context, scope: saved.scope)
                .pendingChanges(journal.cloudRecords()).map(\.recordName)
            let key = try #require(VaultRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        case .settings:
            let journal = SettingsSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try CloudSyncRecordStateStore(context: context, scope: saved.scope)
                .pendingChanges(journal.cloudRecords()).map(\.recordName)
            let key = try #require(SettingsRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        case .metrics:
            let journal = MetricsSyncJournal(context: context)
            pending = try journal.pendingEnvelopes().map(\.key.recordName)
            uploadable = try CloudSyncRecordStateStore(context: context, scope: saved.scope)
                .pendingChanges(journal.cloudRecords()).map(\.recordName)
            let key = try #require(MetricsRecordKey(recordName: saved.recordName))
            #expect(try journal.outgoingEntry(for: key, scope: saved.scope) == nil)
        }
        #expect(pending.contains(saved.recordName))
        #expect(!uploadable.contains(saved.recordName))
        #expect(uploadable.count == 1)
    }

    @Test
    func deletionHandoffSidecarSurvivesDiskReopen() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DeleteHandoff.store")
        let recordName = "handoff/sidecar"
        let old = VaultVersion(
            modifiedAt: Date(timeIntervalSince1970: 100), counter: 1,
            writerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let rebuilt = VaultVersion(
            modifiedAt: Date(timeIntervalSince1970: 200), counter: 2,
            writerID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let delete = CloudSyncMutation(recordName: recordName, operation: .delete, version: old)
        do {
            let container = try TermindPersistence.makeContainer(url: url)
            let state = CloudSyncRecordStateStore(context: container.mainContext, scope: scope)
            try state.observed(recordName)
            try state.recordDeletionHandoff(delete)
            try container.mainContext.save()
        }

        let reopened = try TermindPersistence.makeContainer(url: url)
        let context = reopened.mainContext
        let live = CloudSyncJournalRecord(
            recordName: recordName, version: rebuilt, isDeleted: false,
            needsUpload: true, hasSystemFields: true)
        var cleared: [String] = []
        let replica = CloudSyncReplicaStore.persistent(
            context: context, records: { [live] }, clearSystemFields: { cleared.append($0) })
        let missing = try replica.missing(scope, [])
        try context.save()

        #expect(missing.deleted.isEmpty)
        #expect(missing.recreated == [recordName])
        #expect(cleared == [recordName])
        #expect(
            try CloudSyncRecordStateStore(context: context, scope: scope).pendingChanges([live])
                == [CloudSyncMutation(recordName: recordName, operation: .save, version: rebuilt)])
    }

    @Test
    func emptyInventoryStillDeletesPreviouslyPresentOrdinaryLocalEditAndTerminalHistoryDelete() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let state = CloudSyncRecordStateStore(context: container.mainContext, scope: scope)
        let writer = UUID()
        let live = CloudSyncJournalRecord(
            recordName: "ordinary-edit", version: .baseline(writerID: writer), isDeleted: false,
            needsUpload: true, hasSystemFields: true)
        try state.observed(live.mutation.recordName)
        #expect(try state.missingRecordNames(seen: [], records: [live]).deleted == [live.mutation.recordName])

        let historyDelete = CloudSyncJournalRecord(
            recordName: "v1/connectionHistory/00000000-0000-0000-0000-000000000001",
            version: .baseline(writerID: writer), isDeleted: true, needsUpload: true, hasSystemFields: false)
        try state.observed(historyDelete.mutation.recordName)
        try state.recordDeletionHandoff(historyDelete.mutation)
        let result = try state.missingRecordNames(seen: [], records: [historyDelete])
        #expect(result.deleted.contains(historyDelete.mutation.recordName))
        #expect(result.recreated.isEmpty)
    }

    @Test
    func version30StoreMigratesAndDiscardsRetiredQuarantineTables() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Legacy.store")
        try writeVersion30(to: url)
        let container = try TermindPersistence.makeContainer(url: url)
        let context = container.mainContext
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        #expect(try safety.blockedRecordNames().isEmpty)
        #expect(try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name) == ["Existing data"])
        #expect(!TermindSchemaV30.models.contains { $0 == PersistentCloudSyncQuarantine.self })
        #expect(TermindSchemaV31.models.contains { $0 == PersistentCloudSyncQuarantine.self })
        #expect(!TermindSchemaV40.models.contains { $0 == PersistentVaultSyncQuarantine.self })
        #expect(!TermindSchemaV40.models.contains { $0 == PersistentAIConfigurationSyncQuarantine.self })
        #expect(!TermindSchemaV40.models.contains { $0 == PersistentMetricsSyncQuarantine.self })
        #expect(TermindMigrationPlan.schemas.last?.versionIdentifier == TermindSchemaV40.versionIdentifier)
    }

    @Test
    func version39StoreDropsRetiredTablesAndPreservesScopedSyncState() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Version39.store")
        let testScope = scope
        let recordName = "v1/device/00000000-0000-0000-0000-000000000001"
        do {
            let schema = Schema(versionedSchema: TermindSchemaV39.self)
            let configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            context.insert(PersistentHostGroup(HostGroup(name: "Preserved group")))
            context.insert(
                PersistentVaultSyncQuarantine(recordName: "old-vault", payloadData: Data([1]), reason: "old"))
            context.insert(
                PersistentAIConfigurationSyncQuarantine(
                    recordName: "old-settings", payloadData: Data([2]), reason: "old"))
            context.insert(
                PersistentMetricsSyncQuarantine(recordName: "old-metrics", payloadData: Data([3]), reason: "old"))
            try CloudSyncSafetyStore(context: context, scope: testScope).quarantine(
                recordName: "current", payloadData: Data([4]), reason: "current")
            let state = PersistentCloudSyncRecordState(scope: testScope, recordName: recordName)
            state.wasPresent = true
            state.legacyDeletion = try JSONEncoder().encode(VaultVersion.baseline(writerID: UUID()))
            context.insert(state)
            try context.save()
        }

        let migrated = try TermindPersistence.makeContainer(url: url)
        let context = migrated.mainContext
        #expect(try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.name) == ["Preserved group"])
        #expect(try CloudSyncSafetyStore(context: context, scope: testScope).blockedRecordNames() == ["current"])
        let state = try #require(
            context.fetch(FetchDescriptor<PersistentCloudSyncRecordState>()).first {
                $0.recordName == recordName
            })
        #expect(state.wasPresent)
        #expect(state.legacyDeletion != nil)
        #expect(try CloudSyncRecordStateStore(context: context, scope: testScope).pendingChanges([]).isEmpty)
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
            try #require(fixture.safety().entry(recordName: record.recordID.recordName)?.payloadData)
        )
    }

    private func writeVersion30(to url: URL) throws {
        let schema = Schema(versionedSchema: TermindSchemaV30.self)
        let configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.insert(PersistentHostGroup(HostGroup(name: "Existing data")))
        context.insert(
            PersistentVaultSyncQuarantine(
                recordName: "vault-legacy", payloadData: Data([3, 0]), reason: "legacy error"))
        context.insert(
            PersistentAIConfigurationSyncQuarantine(
                recordName: "settings-legacy", payloadData: Data([3, 0]), reason: "legacy error"))
        context.insert(
            PersistentMetricsSyncQuarantine(
                recordName: "metrics-legacy", payloadData: Data([3, 0]), reason: "legacy error"))
        try context.save()
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

}

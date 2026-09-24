import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncPhysicalDeletionTests {
    @Test(arguments: SyncSafetyCategory.allCases)
    func remoteDeletionCancelsPendingUpdatesAndSurvivesRestart(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let delayed = try #require(fixture.record(id))

        try fixture.receive([delayed], [id])
        try fixture.receive([], [id])

        let scope = try #require(fixture.lifecycle.scope)
        #expect(
            try fixture.cloudRecords().first { $0.mutation.recordName == id.recordName }?.mutation.operation == .delete)
        #expect(try !fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))
        #expect(fixture.batch([.saveRecord(id), .deleteRecord(id)]) == nil)
        #expect(fixture.record(id) == nil)
        #expect(fixture.remoteApplyCount == 1)
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        try await fixture.start()
        #expect(fixture.record(id) == nil)
        #expect(try !fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func localDeletionUsesPhysicalBatchAndOnlyAcknowledgesTheSentDelete(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        let batch = try #require(fixture.batch([.saveRecord(id), .deleteRecord(id)]))
        #expect(batch.recordsToSave.isEmpty)
        #expect(batch.recordIDsToDelete == [id])
        #expect(fixture.record(id) == nil)

        try fixture.sent(
            .init(savedRecords: [], failedRecordSaves: [], failedRecordDeletes: [id: CKError(.networkFailure)]))
        let scope = try #require(fixture.lifecycle.scope)
        #expect(try fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))
        _ = try #require(fixture.batch([.deleteRecord(id)]))
        try fixture.sent(
            .init(savedRecords: [], failedRecordSaves: [], failedRecordDeletes: [id: CKError(.unknownItem)]))
        #expect(try !fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func lateSaveAcknowledgementCannotUndoDeletion(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let delayedSave = try #require(fixture.record(id))
        try fixture.receive([], [id])
        try fixture.sent(.init(savedRecords: [delayedSave], failedRecordSaves: []))
        #expect(fixture.record(id) == nil)
        let batch = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(batch.recordIDsToDelete == [id])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func oldCloudTombstoneIsDeletedEvenWhenItsJournalWasAcknowledged(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let tombstone = try Self.tombstone(try #require(fixture.record(id)))
        try fixture.receive([tombstone], [])
        #expect(try !fixture.pendingNames().contains(id.recordName))
        #expect(fixture.record(id) == nil)
        let batch = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(batch.recordIDsToDelete == [id])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        try await fixture.start()
        #expect(fixture.batch([.saveRecord(id), .deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func fullRefetchRemovesPreviouslySyncedMissingRecordsAndKeepsNewLocalRecords(category: SyncSafetyCategory)
        async throws
    {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let synced = fixture.recordIDs[0]
        let newLocal = fixture.recordIDs[1]
        try fixture.receive([try #require(fixture.record(synced))], [])
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        try await fixture.start()

        #expect(fixture.record(synced) == nil)
        #expect(
            try fixture.cloudRecords().first { $0.mutation.recordName == synced.recordName }?.mutation.operation
                == .delete)
        #expect(fixture.record(newLocal) != nil)
        #expect(fixture.batch([.saveRecord(synced), .deleteRecord(synced)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func failedFullFetchDoesNotInferDeletionsFromAnIncompleteInventory(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let records = try fixture.recordIDs.map { try #require(fixture.record($0)) }
        try fixture.receive(records, [])
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = {
            try fixture.receive([records[0]], [])
            throw CKError(.networkFailure)
        }
        fixture.lifecycle.start()
        await fixture.lifecycle.operation?.value
        #expect(!fixture.lifecycle.isReadyToSend)
        #expect(try fixture.cloudRecords().allSatisfy { $0.mutation.operation == .save })
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func unknownItemForAnExistingRecordAppliesRemoteDeletion(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let record = try #require(fixture.record(id))
        try fixture.receive([record], [])
        try fixture.sent(
            .init(savedRecords: [], failedRecordSaves: [.init(record: record, error: CKError(.unknownItem))]))
        #expect(
            try fixture.cloudRecords().first { $0.mutation.recordName == id.recordName }?.mutation.operation == .delete)
        #expect(fixture.batch([.saveRecord(id), .deleteRecord(id)]) == nil)
    }

    @Test
    func historyRetentionAndClearUseDeletesWithoutTouchingDevices() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .history)
        defer { fixture.stop() }
        try await fixture.start()
        let zone = fixture.lifecycle.zoneID
        let device = DeviceRecord(id: UUID(), displayName: "Device")
        fixture.container.mainContext.insert(PersistentDeviceRecord(device))
        let records = try (0..<300).map { index in
            let entry = ConnectionHistoryEntry(
                hostID: UUID(), kind: .ssh, connectedAt: Date.now.addingTimeInterval(Double(index + 1)))
            let envelope = HistoryEnvelope(
                key: .init(kind: .connectionHistory, id: entry.id),
                version: .baseline(writerID: UUID()), payload: .connectionHistory(entry))
            return try HistoryRecordSyncCoordinator.makeRecord(
                .init(envelope: envelope),
                recordID: .init(recordName: envelope.key.recordName, zoneID: zone))
        }
        try fixture.receive(records, [])
        #expect(
            try fixture.container.mainContext.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 250)
        var server = Set(records.map(\.recordID))
        while let batch = fixture.batch(fixture.network.nextEngine.pendingChanges) {
            #expect(batch.recordsToSave.count + batch.recordIDsToDelete.count <= 250)
            #expect(
                batch.recordIDsToDelete.allSatisfy {
                    HistoryRecordKey(recordName: $0.recordName)?.kind == .connectionHistory
                })
            server.subtract(batch.recordIDsToDelete)
            try fixture.sent(
                .init(
                    savedRecords: batch.recordsToSave, failedRecordSaves: [], deletedRecordIDs: batch.recordIDsToDelete)
            )
        }
        #expect(server.count == 250)
        try SwiftDataConnectionHistoryRepository(context: fixture.container.mainContext).clearAll()
        try fixture.lifecycle.reconcilePendingChanges()
        while let batch = fixture.batch(fixture.network.nextEngine.pendingChanges) {
            server.subtract(batch.recordIDsToDelete)
            try fixture.sent(
                .init(
                    savedRecords: batch.recordsToSave, failedRecordSaves: [], deletedRecordIDs: batch.recordIDsToDelete)
            )
        }
        #expect(server.isEmpty)
        #expect(try fixture.container.mainContext.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
    }

    @Test
    func manualHistoryDeletionAndLocalOverflowBothScheduleCloudDeletes() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .history)
        defer { fixture.stop() }
        try await fixture.start()
        let context = fixture.container.mainContext
        let repository = SwiftDataConnectionHistoryRepository(context: context)
        repository.didRecordHistoryChanges = { fixture.lifecycle.noteLocalChanges($0.keys.map(\.recordName)) }
        let firstID = fixture.recordIDs[0]
        let firstKey = try #require(HistoryRecordKey(recordName: firstID.recordName))
        try repository.delete(firstKey.id)
        let manual = try #require(fixture.batch([.deleteRecord(firstID)]))
        #expect(manual.recordIDsToDelete == [firstID])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [firstID]))

        let oldID = fixture.recordIDs[1]
        let host = UUID()
        for index in 0..<ConnectionHistoryModel.limit {
            try repository.insert(
                ConnectionHistoryEntry(
                    hostID: host, kind: .sftp, connectedAt: Date.now.addingTimeInterval(Double(index + 1))),
                limit: ConnectionHistoryModel.limit)
        }
        let overflow = try #require(fixture.batch([.deleteRecord(oldID)]))
        #expect(overflow.recordIDsToDelete == [oldID])
        #expect(try repository.entries().count == 250)
        try repository.clear(for: host)
        #expect(try repository.entries().isEmpty)
        let scope = try #require(fixture.lifecycle.scope)
        #expect(try fixture.lifecycle.store.pendingChanges(scope).allSatisfy { $0.operation == .delete })
    }

    @Test
    func obsoleteVaultCopiesAreDeletedWithoutImportingOrApplyingTheirDeletionEvents() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault)
        defer { fixture.stop() }
        try await fixture.start()
        let context = fixture.container.mainContext
        let event = ConnectionHistoryEntry(hostID: UUID(), kind: .ssh)
        let device = DeviceRecord(id: UUID(), displayName: "Current device")
        let native = HistorySyncPersistence(context: context)
        let version = VaultVersion.baseline(writerID: UUID())
        let payloads: [HistoryRecordPayload] = [.connectionHistory(event), .device(device)]
        _ = try native.applyRemote(payloads.map { HistoryEnvelope(key: $0.key, version: version, payload: $0) })
        let oldRecords = payloads.map { payload in
            let record = CKRecord(
                recordType: VaultSyncCoordinator.recordType,
                recordID: .init(recordName: payload.key.recordName, zoneID: fixture.lifecycle.zoneID))
            // Old copies are obsolete even if their payload is unreadable to the new decoder.
            record["payload"] = Data([0xff]) as NSData
            return record
        }
        try fixture.receive(oldRecords, [])
        try fixture.receive([], oldRecords.map(\.recordID))
        #expect(try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
        #expect(fixture.remoteApplyCount == 0)
        let batch = try #require(fixture.batch(oldRecords.map { .deleteRecord($0.recordID) }))
        #expect(Set(batch.recordIDsToDelete) == Set(oldRecords.map(\.recordID)))
        #expect(batch.recordsToSave.isEmpty)
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: batch.recordIDsToDelete))
        #expect(fixture.batch(oldRecords.map { .deleteRecord($0.recordID) }) == nil)

        let activeZone = CKRecordZone.ID(zoneName: ConnectionHistorySyncCoordinator.zoneName)
        let active = try payloads.map { payload in
            try HistoryRecordSyncCoordinator.makeRecord(
                .init(envelope: .init(key: payload.key, version: version, payload: payload)),
                recordID: .init(recordName: payload.key.recordName, zoneID: activeZone))
        }
        try fixture.receive(active, active.map(\.recordID))
        #expect(fixture.batch(active.map { .deleteRecord($0.recordID) }) == nil)
        #expect(try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
    }

    @Test
    func deviceLaunchRegistrationDoesNotRecreateADeletedDeviceButRenameCan() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .device)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let key = try #require(HistoryRecordKey(recordName: id.recordName))
        try fixture.receive([], [id])
        let model = DeviceDirectoryModel(
            repository: SwiftDataDeviceDirectoryRepository(context: fixture.container.mainContext),
            currentDeviceID: key.id, currentDeviceName: "Deleted device")
        #expect(!model.devices().contains { $0.id == key.id })
        #expect(fixture.record(id) == nil)
        model.updateCurrentDeviceName("Explicit rename")
        #expect(model.devices().contains { $0.id == key.id && $0.displayName == "Explicit rename" })
        #expect(fixture.record(id) != nil)
    }

    @Test
    func settingsRecreationWaitsForInFlightDeletionAndSurvivesItsAcknowledgement() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .settings)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let key = try #require(SettingsRecordKey(recordName: id.recordName))
        let context = fixture.container.mainContext
        let journal = SettingsSyncJournal(context: context)
        let saved = try #require(fixture.record(id))
        try fixture.receive([saved], [])
        try fixture.markTombstone()
        _ = try #require(fixture.batch([.deleteRecord(id)]))
        var replacement = try SettingsSyncCoordinator.envelope(from: saved)
        replacement.version = .next(after: try journal.envelope(for: key)?.version, writerID: UUID())
        try journal.acceptRemote([replacement])
        try journal.markNeedsUpload([key])
        try context.save()
        #expect(fixture.batch([.saveRecord(id)]) == nil)
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        let scope = try #require(fixture.lifecycle.scope)
        #expect(
            try fixture.lifecycle.store.pendingChanges(scope).contains {
                $0.recordName == id.recordName && $0.operation == .save && $0.version == replacement.version
            })
        #expect(try !CloudSyncRecordStateStore(context: context, scope: scope).wasPresent(id.recordName))
        #expect(fixture.batch([.saveRecord(id)])?.recordsToSave.count == 1)
    }

    @Test
    func version36MigrationPreservesJournalsAndPersistsScopedDeletionAcknowledgements() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Migration.store")
        let key = HistoryRecordKey(kind: .connectionHistory, id: UUID())
        let version = VaultVersion.baseline(writerID: UUID())
        try Self.writeVersion36Tombstone(url: url, key: key, version: version)
        let scope = CloudSyncScope(
            container: "test", environment: "Production", account: "account", zone: "history", owner: "owner")
        try Self.migrateAndAcknowledge(url: url, key: key, version: version, scope: scope)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let journal = HistorySyncJournal(context: reopened.mainContext)
        let records = try journal.cloudRecords()
        #expect(try journal.envelope(for: key)?.isDeleted == true)
        #expect(
            try CloudSyncRecordStateStore(context: reopened.mainContext, scope: scope).pendingChanges(records).isEmpty)
        var differentAccount = scope
        differentAccount.account = "another-account"
        #expect(
            try CloudSyncRecordStateStore(context: reopened.mainContext, scope: differentAccount).pendingChanges(
                records
            ).count == 1)
    }

    private static func writeVersion36Tombstone(url: URL, key: HistoryRecordKey, version: VaultVersion) throws {
        let schema = Schema(versionedSchema: TermindSchemaV36.self)
        let configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        container.mainContext.insert(
            try PersistentHistorySyncEntry(
                envelope: .init(key: key, version: version, isDeleted: true), needsUpload: false))
        try container.mainContext.save()
    }

    private static func migrateAndAcknowledge(
        url: URL, key: HistoryRecordKey, version: VaultVersion, scope: CloudSyncScope
    ) throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let journal = HistorySyncJournal(context: container.mainContext)
        let cloud = CloudSyncRecordStateStore(context: container.mainContext, scope: scope)
        #expect(try cloud.prepare(journal.cloudRecords()))
        let changes = try cloud.pendingChanges(journal.cloudRecords())
        #expect(changes == [.init(recordName: key.recordName, operation: .delete, version: version)])
        try journal.acknowledgeDeletion(try #require(changes.first), scope: scope)
        try cloud.completeReconciliation()
        try container.mainContext.save()
    }

    private static func tombstone(_ record: CKRecord) throws -> CKRecord {
        switch record.recordType {
        case "VaultItem":
            var envelope = try VaultSyncCoordinator.envelope(from: record)
            envelope.version.counter += 1
            envelope.isDeleted = true
            envelope.payload = nil
            return try VaultSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        case "MetricsItem":
            var envelope = try MetricsSyncCoordinator.envelope(from: record)
            envelope.version.counter += 1
            envelope.isDeleted = true
            envelope.payload = nil
            return try MetricsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        case "ConnectionHistoryItem", "DeviceItem":
            var envelope = try HistoryRecordSyncCoordinator.envelope(from: record)
            envelope.version.counter += 1
            envelope.isDeleted = true
            envelope.payload = nil
            return try HistoryRecordSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        default:
            var envelope = try SettingsSyncCoordinator.envelope(from: record)
            envelope.version.counter += 1
            envelope.isDeleted = true
            envelope.payload = nil
            return try SettingsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        }
    }
}

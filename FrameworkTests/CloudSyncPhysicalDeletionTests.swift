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
    func destructiveZoneReasonsPurgeOnlyTheActiveReplicaAndCannotResendOldSnapshot(
        category: SyncSafetyCategory
    ) async throws {
        for reason in [CloudSyncZoneDeletionReason.purged, .encryptedDataReset] {
            let fixture = try CloudSyncSafetyFixture(category: category)
            defer { fixture.stop() }
            try await fixture.start()
            let records = try fixture.recordIDs.map { try fixture.newerRecord($0) }
            try fixture.receive(records, [])
            #expect(try fixture.projectionIsPopulated())
            #expect(fixture.remoteApplyCount == 1)
            let scope = try #require(fixture.lifecycle.scope)
            let safety = CloudSyncSafetyStore(context: fixture.container.mainContext, scope: scope)
            try safety.quarantine(recordName: "active-only", payloadData: Data([1]), reason: "purge")
            var otherScope = scope
            otherScope.account = "other-account"
            let other = CloudSyncSafetyStore(context: fixture.container.mainContext, scope: otherScope)
            try other.quarantine(recordName: "active-only", payloadData: Data([2]), reason: "keep")
            try fixture.container.mainContext.save()
            let engine = fixture.network.nextEngine

            fixture.lifecycle.handle(
                .fetchedDatabaseChanges(deletions: [(fixture.lifecycle.zoneID, reason)]), engine: engine,
                receiveRemoteRecords: { try fixture.receive($0, $1) },
                handleSentChanges: { try fixture.sent($0) })

            #expect(fixture.lifecycle.engine == nil)
            #expect(try fixture.projectionIsCleared())
            #expect(fixture.remoteApplyCount == 2)
            #expect(fixture.remoteApplyObservedCleared)
            #expect(try safety.blockedRecordNames().isEmpty)
            #expect(try other.entry(recordName: "active-only")?.payloadData == Data([2]))
            fixture.network.nextEngine = LifecycleEngine()
            fixture.lifecycle.start()
            await fixture.lifecycle.operation?.value
            let pending = try fixture.lifecycle.store.pendingChanges(try #require(fixture.lifecycle.scope))
            #expect(Set(pending.map(\.recordName)).isDisjoint(with: fixture.recordIDs.map(\.recordName)))
            #expect(
                fixture.batch(
                    fixture.recordIDs.flatMap { [.saveRecord($0), .deleteRecord($0)] }) == nil)
        }
    }

    @Test(arguments: [SyncSafetyCategory.vault, .settings, .metrics])
    func destructivePurgeRemovesOnlyTheCategoryOwnedLargePayloadAssets(
        category: SyncSafetyCategory
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try CloudSyncSafetyFixture(category: category, assetCacheRoot: root)
        defer { fixture.stop() }
        try await fixture.start()

        let directoryName = try #require(Self.assetDirectoryName(for: category))
        let assetURL = try CloudSyncRecordCoding.assetURL(
            recordName: fixture.recordIDs[0].recordName, directoryName: directoryName, cacheRoot: root)
        let record = CKRecord(recordType: "LargePayload", recordID: fixture.recordIDs[0])
        try CloudSyncRecordCoding.setPayload(
            Data(repeating: 0x5a, count: CloudSyncRecordCoding.inlinePayloadLimit + 1),
            on: record, assetURL: assetURL)
        #expect(record["payloadAsset"] is CKAsset)
        #expect(FileManager.default.fileExists(atPath: assetURL.path))

        let unrelated = root.appending(path: "Unrelated/keep")
        try FileManager.default.createDirectory(
            at: unrelated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: unrelated)

        let engine = fixture.network.nextEngine
        fixture.lifecycle.handle(
            .fetchedDatabaseChanges(deletions: [(fixture.lifecycle.zoneID, .purged)]), engine: engine,
            receiveRemoteRecords: { try fixture.receive($0, $1) },
            handleSentChanges: { try fixture.sent($0) })

        #expect(!FileManager.default.fileExists(atPath: assetURL.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test
    func assetPurgeFailureRetiresSyncAfterDurableProjectionPurge() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = directory.appending(path: "Caches")
        let storeURL = directory.appendingPathComponent("AssetCleanup.store")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetURL = try CloudSyncRecordCoding.assetURL(
            recordName: "large/payload",
            directoryName: VaultSyncCoordinator.assetDirectoryName, cacheRoot: root)
        let assetID = CKRecord.ID(recordName: "large/payload")
        let record = CKRecord(recordType: "LargePayload", recordID: assetID)
        try CloudSyncRecordCoding.setPayload(
            Data(repeating: 0x5a, count: CloudSyncRecordCoding.inlinePayloadLimit + 1),
            on: record, assetURL: assetURL)
        var savedScope: CloudSyncScope?

        do {
            let fixture = try CloudSyncSafetyFixture(
                category: .vault, url: storeURL, assetCacheRoot: root,
                removeAssetDirectory: { _ in throw CocoaError(.fileWriteUnknown) })
            try await fixture.start()
            let records = try fixture.recordIDs.map { try fixture.newerRecord($0) }
            try fixture.receive(records, [])
            #expect(try fixture.projectionIsPopulated())
            let scope = try #require(fixture.lifecycle.scope)
            savedScope = scope

            let engine = fixture.network.nextEngine
            fixture.lifecycle.handle(
                .fetchedDatabaseChanges(deletions: [(fixture.lifecycle.zoneID, .purged)]), engine: engine,
                receiveRemoteRecords: { try fixture.receive($0, $1) },
                handleSentChanges: { try fixture.sent($0) })

            #expect(fixture.lifecycle.engine == nil)
            #expect(try fixture.projectionIsCleared())
            #expect(FileManager.default.fileExists(atPath: assetURL.path))
            #expect(fixture.remoteApplyCount == 2)
            #expect(fixture.remoteApplyObservedCleared)
            #expect(try fixture.lifecycle.store.pendingChanges(scope).isEmpty)
            #expect(
                try CloudSyncAssetCleanupStore(context: fixture.container.mainContext).isPending(
                    scope: scope, cacheKey: VaultSyncCoordinator.assetDirectoryName))
            fixture.stop()
        }

        let scope = try #require(savedScope)
        do {
            let failedRestart = try CloudSyncSafetyFixture(
                category: .vault, url: storeURL, seed: false, assetCacheRoot: root,
                removeAssetDirectory: { _ in throw CocoaError(.fileWriteUnknown) })
            failedRestart.lifecycle.start()
            await failedRestart.lifecycle.operation?.value
            #expect(failedRestart.lifecycle.engine == nil)
            #expect(!failedRestart.lifecycle.isReadyToSend)
            let isUpToDate = if case .upToDate = failedRestart.lifecycle.status { true } else { false }
            #expect(!isUpToDate)
            #expect(FileManager.default.fileExists(atPath: assetURL.path))
            #expect(
                try CloudSyncAssetCleanupStore(context: failedRestart.container.mainContext).isPending(
                    scope: scope, cacheKey: VaultSyncCoordinator.assetDirectoryName))
            #expect(failedRestart.batch(failedRestart.recordIDs.map { .saveRecord($0) }) == nil)
            failedRestart.stop()
        }

        let recovered = try CloudSyncSafetyFixture(
            category: .vault, url: storeURL, seed: false, assetCacheRoot: root)
        defer { recovered.stop() }
        let changedBinding = try VaultSyncJournal(context: recovered.container.mainContext).state()
        changedBinding.boundUserRecordName = "previous-account"
        recovered.defaults.set("PreviousEnvironment", forKey: SettingsKey.vaultSyncEnvironment)
        try recovered.container.mainContext.save()
        recovered.lifecycle.start()
        await recovered.lifecycle.operation?.value
        #expect(!FileManager.default.fileExists(atPath: assetURL.deletingLastPathComponent().path))
        #expect(
            try !CloudSyncAssetCleanupStore(context: recovered.container.mainContext).isPending(
                scope: scope, cacheKey: VaultSyncCoordinator.assetDirectoryName))
        #expect(recovered.lifecycle.status == .accountChangeConfirmationRequired)
        #expect(recovered.lifecycle.engine == nil)

        recovered.lifecycle.confirmAccountSwitchMerge()
        await recovered.lifecycle.operation?.value
        #expect(recovered.lifecycle.isReadyToSend)
        #expect(recovered.batch(recovered.recordIDs.map { .saveRecord($0) }) == nil)
    }

    @Test
    func vaultPurgeRemovesScopedQuarantineOnlyInActiveScope() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault)
        defer { fixture.stop() }
        try await fixture.start()
        let scope = try #require(fixture.lifecycle.scope)
        let safety = CloudSyncSafetyStore(context: fixture.container.mainContext, scope: scope)
        let legacyNames = [
            HistoryRecordKey(kind: .connectionHistory, id: UUID()).recordName,
            HistoryRecordKey(kind: .device, id: UUID()).recordName,
        ]
        for name in legacyNames {
            try safety.quarantine(
                recordName: name, payloadData: Data(repeating: 7, count: 32), reason: "legacy")
        }
        try fixture.container.mainContext.save()
        for name in legacyNames { #expect(try safety.entry(recordName: name) != nil) }

        var otherScope = scope
        otherScope.account = "other-account"
        let other = CloudSyncSafetyStore(context: fixture.container.mainContext, scope: otherScope)
        try other.quarantine(recordName: legacyNames[0], payloadData: Data([9]), reason: "other")
        try fixture.container.mainContext.save()

        let engine = fixture.network.nextEngine
        fixture.lifecycle.handle(
            .fetchedDatabaseChanges(deletions: [(fixture.lifecycle.zoneID, .encryptedDataReset)]), engine: engine,
            receiveRemoteRecords: { try fixture.receive($0, $1) },
            handleSentChanges: { try fixture.sent($0) })

        for name in legacyNames { #expect(try safety.entry(recordName: name) == nil) }
        #expect(try other.entry(recordName: legacyNames[0])?.payloadData == Data([9]))
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func restartAfterHandedOffDeleteKeepsExplicitNewIncarnationsAndTerminalHistory(
        category: SyncSafetyCategory
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("DeleteHandoff.store")
        let recordName: String

        do {
            let fixture = try CloudSyncSafetyFixture(category: category, url: url)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            recordName = id.recordName
            try fixture.receive([try fixture.newerRecord(id)], [])
            try fixture.markTombstone()
            try fixture.lifecycle.reconcilePendingChanges()
            let batch = try #require(fixture.batch([.saveRecord(id), .deleteRecord(id)]))
            #expect(batch.recordsToSave.isEmpty)
            #expect(batch.recordIDsToDelete == [id])
            fixture.stop()
        }

        let reopened = try CloudSyncSafetyFixture(category: category, url: url, seed: false)
        defer { reopened.stop() }
        let recreated = try reopened.recreateFirst()
        try await reopened.start()
        let id = reopened.recordIDs[0]
        #expect(id.recordName == recordName)
        let journalRecord = try #require(
            reopened.cloudRecords().first { $0.mutation.recordName == recordName })

        if category == .history {
            #expect(!recreated)
            #expect(journalRecord.mutation.operation == .delete)
            #expect(reopened.record(id) == nil)
        } else {
            #expect(recreated)
            #expect(journalRecord.mutation.operation == .save)
            #expect(journalRecord.needsUpload)
            #expect(!journalRecord.hasSystemFields)
            let batch = try #require(reopened.batch([.saveRecord(id), .deleteRecord(id)]))
            #expect(batch.recordsToSave.map(\.recordID) == [id])
            #expect(batch.recordIDsToDelete.isEmpty)
        }
    }

    @Test(arguments: [SyncSafetyCategory.vault, .settings, .metrics, .device])
    func staleSaveAndDeleteAcknowledgementsCannotEraseARecreatedIncarnation(
        category: SyncSafetyCategory
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("StaleAcknowledgement.store")

        do {
            let fixture = try CloudSyncSafetyFixture(category: category, url: url)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let delayedSave = try #require(fixture.record(id))
            try fixture.receive([delayedSave], [])
            try fixture.markTombstone()
            try fixture.lifecycle.reconcilePendingChanges()
            _ = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(try fixture.recreateFirst())
            try fixture.lifecycle.reconcilePendingChanges()
            try fixture.sent(
                .init(savedRecords: [delayedSave], failedRecordSaves: [], deletedRecordIDs: [id]))
            fixture.stop()
        }

        let reopened = try CloudSyncSafetyFixture(category: category, url: url, seed: false)
        defer { reopened.stop() }
        try await reopened.start()
        let id = reopened.recordIDs[0]
        let row = try #require(reopened.cloudRecords().first { $0.mutation.recordName == id.recordName })
        #expect(row.mutation.operation == .save)
        #expect(row.needsUpload)
        #expect(reopened.record(id) != nil)
    }

    @Test(arguments: [SyncSafetyCategory.vault, .settings, .metrics, .device])
    func acknowledgedRecreationMakesLaterEditsSubjectToRealRemoteDeletion(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        try fixture.receive([try #require(fixture.record(id))], [])
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        _ = try #require(fixture.batch([.deleteRecord(id)]))
        try fixture.sent(
            .init(
                savedRecords: [], failedRecordSaves: [],
                failedRecordDeletes: [id: CKError(.networkFailure)]))

        #expect(try fixture.recreateFirst())
        try fixture.lifecycle.reconcilePendingChanges()
        let recreated = try #require(fixture.batch([.saveRecord(id)]))
        #expect(recreated.recordsToSave.map(\.recordID) == [id])
        #expect(try fixture.editFirstAgain())
        try fixture.lifecycle.reconcilePendingChanges()

        try fixture.sent(.init(savedRecords: recreated.recordsToSave, failedRecordSaves: []))
        try fixture.receive([], [id])

        let row = try #require(fixture.cloudRecords().first { $0.mutation.recordName == id.recordName })
        #expect(row.mutation.operation == .delete)
        #expect(fixture.record(id) == nil)
        #expect(fixture.batch([.saveRecord(id)]) == nil)
    }

    @Test(arguments: [SyncSafetyCategory.vault, .settings, .metrics, .device])
    func ambiguousDeleteFailureKeepsRecreatedIncarnationAcrossRestart(
        category: SyncSafetyCategory
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("AmbiguousDelete.store")

        do {
            let fixture = try CloudSyncSafetyFixture(category: category, url: url)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            try fixture.receive([try #require(fixture.record(id))], [])
            try fixture.markTombstone()
            try fixture.lifecycle.reconcilePendingChanges()
            _ = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(try fixture.recreateFirst())
            try fixture.lifecycle.reconcilePendingChanges()
            try fixture.sent(
                .init(
                    savedRecords: [], failedRecordSaves: [],
                    failedRecordDeletes: [id: CKError(.networkFailure)]))
            fixture.stop()
        }

        let reopened = try CloudSyncSafetyFixture(category: category, url: url, seed: false)
        defer { reopened.stop() }
        try await reopened.start()
        let id = reopened.recordIDs[0]
        let row = try #require(reopened.cloudRecords().first { $0.mutation.recordName == id.recordName })
        #expect(row.mutation.operation == .save)
        #expect(row.needsUpload)
        #expect(reopened.record(id) != nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func incrementalDeletionConfirmsOnlyTheHandedOffIncarnation(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        try fixture.receive([try #require(fixture.record(id))], [])
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        _ = try #require(fixture.batch([.deleteRecord(id)]))
        let recreated = try fixture.recreateFirst()
        try fixture.lifecycle.reconcilePendingChanges()

        try fixture.receive([], [id])
        try fixture.receive([], [id])
        let row = try #require(fixture.cloudRecords().first { $0.mutation.recordName == id.recordName })
        if category == .history {
            #expect(!recreated)
            #expect(row.mutation.operation == .delete)
            #expect(fixture.record(id) == nil)
        } else {
            #expect(recreated)
            #expect(row.mutation.operation == .save)
            #expect(row.needsUpload)
            #expect(fixture.record(id) != nil)
        }
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func confirmedTombstoneReobservationSchedulesAnotherPhysicalDelete(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let tombstone = try Self.tombstone(try #require(fixture.record(id)))
        try fixture.receive([tombstone], [])
        let first = try #require(fixture.batch([.deleteRecord(id)]))
        try fixture.sent(
            .init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: first.recordIDsToDelete))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)

        try fixture.receive([tombstone], [])
        let retry = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(retry.recordIDsToDelete == [id])
    }

    @Test
    func unknownItemForOldSettingsSavePreservesRecreatedIncarnationAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("UnknownItem.store")

        do {
            let fixture = try CloudSyncSafetyFixture(category: .settings, url: url)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let delayedSave = try #require(fixture.record(id))
            try fixture.receive([delayedSave], [])
            try fixture.markTombstone()
            try fixture.lifecycle.reconcilePendingChanges()
            _ = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(try fixture.recreateFirst())
            try fixture.lifecycle.reconcilePendingChanges()
            try fixture.sent(
                .init(
                    savedRecords: [],
                    failedRecordSaves: [.init(record: delayedSave, error: CKError(.unknownItem))]))
            fixture.stop()
        }

        let reopened = try CloudSyncSafetyFixture(category: .settings, url: url, seed: false)
        defer { reopened.stop() }
        try await reopened.start()
        let id = reopened.recordIDs[0]
        let row = try #require(reopened.cloudRecords().first { $0.mutation.recordName == id.recordName })
        #expect(row.mutation.operation == .save)
        #expect(row.needsUpload)
        #expect(reopened.record(id) != nil)
    }

    @Test(arguments: [false, true])
    func oldLiveAfterIncrementalDeleteCannotResetNewIncarnationEvidence(
        asSaveAcknowledgement: Bool
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("OldLiveAfterDelete.store")

        do {
            let fixture = try CloudSyncSafetyFixture(category: .settings, url: url)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let oldLive = try #require(fixture.record(id))
            try fixture.receive([oldLive], [])
            try fixture.markTombstone()
            try fixture.lifecycle.reconcilePendingChanges()
            _ = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(try fixture.recreateFirst())
            try fixture.lifecycle.reconcilePendingChanges()
            try fixture.receive([], [id])
            if asSaveAcknowledgement {
                try fixture.sent(.init(savedRecords: [oldLive], failedRecordSaves: []))
            } else {
                try fixture.receive([oldLive], [])
            }
            fixture.stop()
        }

        let reopened = try CloudSyncSafetyFixture(category: .settings, url: url, seed: false)
        defer { reopened.stop() }
        try await reopened.start()
        let id = reopened.recordIDs[0]
        let row = try #require(reopened.cloudRecords().first { $0.mutation.recordName == id.recordName })
        #expect(row.mutation.operation == .save)
        #expect(row.needsUpload)
        #expect(reopened.record(id) != nil)
    }

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
        #expect(fixture.batch([.deleteRecord(id)]) == nil)

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

    /// A failed (or unreported) send must not strand the physical delete; with
    /// overlapping sends the release waits for the last completion.
    @Test(arguments: SyncSafetyCategory.allCases, [false, true])
    func failedSendsReleasePhysicalDeleteForRetry(
        category: SyncSafetyCategory, overlapping: Bool
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        try fixture.lifecycle.beginSend()
        if overlapping { try fixture.lifecycle.beginSend() }
        _ = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)

        try fixture.lifecycle.finishSend(succeeded: false)

        if overlapping {
            #expect(fixture.batch([.deleteRecord(id)]) == nil)
            try fixture.lifecycle.finishSend(succeeded: false)
        }
        let retry = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(retry.recordIDsToDelete == [id])
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
    func fetchedRecordObservedAfterDeleteHandoffRequiresAnotherPhysicalDelete(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let delayedRecord = try #require(fixture.record(id))
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        let firstDelete = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(firstDelete.recordIDsToDelete == [id])

        try fixture.receive([delayedRecord], [])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.record(id) == nil)
        let scope = try #require(fixture.lifecycle.scope)
        #expect(try fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))

        // A replayed acknowledgement has no handed-off operation to acknowledge.
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(try fixture.lifecycle.store.pendingRecordNames(scope).contains(id.recordName))
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        fixture.network.nextEngine.fetchBody = { try fixture.receive([delayedRecord], []) }
        try await fixture.start()
        let retry = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(retry.recordIDsToDelete == [id])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func fetchedDeletionWinsOverSameBatchRecordDuringDeleteHandoff(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let staleRecord = try #require(fixture.record(id))
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        _ = try #require(fixture.batch([.deleteRecord(id)]))

        try fixture.receive([staleRecord], [id])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))

        #expect(fixture.record(id) == nil)
        #expect(fixture.batch([.deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func savedRecordObservedAfterDeleteHandoffRequiresAnotherPhysicalDelete(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let delayedSave = try #require(fixture.record(id))
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        _ = try #require(fixture.batch([.deleteRecord(id)]))

        try fixture.sent(.init(savedRecords: [delayedSave], failedRecordSaves: []))
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.record(id) == nil)
        let retry = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(retry.recordIDsToDelete == [id])
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        #expect(fixture.batch([.deleteRecord(id)]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func olderAndEqualLiveRecordsCannotReviveAConfirmedPhysicalDeletion(
        category: SyncSafetyCategory
    ) async throws {
        for (useRemoteDeletion, useEqualVersion) in [
            (false, false), (false, true), (true, false), (true, true),
        ] {
            let fixture = try CloudSyncSafetyFixture(category: category)
            defer { fixture.stop() }
            let id = fixture.recordIDs[0]
            try await fixture.start()
            let original = try #require(fixture.record(id))
            if useRemoteDeletion {
                try fixture.receive([], [id])
            } else {
                try fixture.markTombstone()
                try fixture.lifecycle.reconcilePendingChanges()
                _ = try #require(fixture.batch([.deleteRecord(id)]))
                try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
            }
            let deletion = try #require(
                fixture.cloudRecords().first { $0.mutation.recordName == id.recordName }?.mutation)

            let delayed =
                try useEqualVersion
                ? Self.liveRecord(original, version: deletion.version)
                : fixture.olderRecord(id)
            try fixture.receive([delayed], [])
            let local = try #require(
                fixture.cloudRecords().first { $0.mutation.recordName == id.recordName })
            #expect(local.mutation.operation == .delete)
            #expect(try fixture.pendingNames().contains(id.recordName))
            // An ID-only result that has no handed-off delete cannot clear this retry.
            try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
            #expect(try fixture.pendingNames().contains(id.recordName))
            let retry = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(retry.recordIDsToDelete == [id])
            try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        }
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func trulyNewerLiveRecordFollowsTheCategoryProtocolAfterConfirmedDeletion(
        category: SyncSafetyCategory
    ) async throws {
        for useRemoteDeletion in [false, true] {
            let fixture = try CloudSyncSafetyFixture(category: category)
            defer { fixture.stop() }
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let original = try #require(fixture.record(id))
            if useRemoteDeletion {
                try fixture.receive([], [id])
            } else {
                try fixture.markTombstone()
                try fixture.lifecycle.reconcilePendingChanges()
                _ = try #require(fixture.batch([.deleteRecord(id)]))
                try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
            }
            let deletion = try #require(
                fixture.cloudRecords().first { $0.mutation.recordName == id.recordName }?.mutation)
            var newerVersion = deletion.version
            newerVersion.counter += 1

            try fixture.receive([try Self.liveRecord(original, version: newerVersion)], [])

            let local = try #require(fixture.cloudRecords().first { $0.mutation.recordName == id.recordName })
            if category == .history {
                #expect(local.mutation.operation == .delete)
                #expect(try fixture.pendingNames().contains(id.recordName))
            } else {
                #expect(local.mutation.operation == .save)
                #expect(try !fixture.pendingNames().contains(id.recordName))
            }
        }
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func quarantinedObservationReleasesCompletedDeleteBeforeSupportedRecovery(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let supported = try #require(fixture.record(id))
        let future = try fixture.futureRecord()
        try fixture.markTombstone()
        try fixture.lifecycle.reconcilePendingChanges()
        _ = try #require(fixture.batch([.deleteRecord(id)]))

        try fixture.receive([future], [])
        #expect(try fixture.safety().isUploadBlocked(recordName: id.recordName))
        try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
        try fixture.receive([supported], [])
        #expect(try !fixture.safety().isUploadBlocked(recordName: id.recordName))
        let retry = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(retry.recordIDsToDelete == [id])
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
    func obsoleteVaultCopiesAreIgnoredWithoutImportingOrApplyingTheirDeletionEvents() async throws {
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
        let safety = try fixture.safety()
        for record in oldRecords {
            try safety.quarantine(
                recordName: record.recordID.recordName, payloadData: Data([0xff]), reason: "Retired copy")
        }
        try context.save()
        try fixture.receive(oldRecords, [])
        try fixture.receive([], oldRecords.map(\.recordID))
        #expect(try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 1)
        #expect(try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
        #expect(fixture.remoteApplyCount == 0)
        #expect(try safety.blockedRecordNames() == Set(oldRecords.map { $0.recordID.recordName }))
        #expect(fixture.batch(oldRecords.map { .deleteRecord($0.recordID) }) == nil)
        #expect(fixture.batch(oldRecords.map { .saveRecord($0.recordID) }) == nil)
        try fixture.receive(oldRecords, oldRecords.map(\.recordID))
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
    func oldVaultHistoryAndDeviceCopiesAndQueuedDeletesStaySkippedAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LegacyCopies.store")
        var savedScope: CloudSyncScope?
        var recordNames = Set<String>()

        do {
            let fixture = try CloudSyncSafetyFixture(category: .vault, url: url)
            try await fixture.start()
            let context = fixture.container.mainContext
            let cases: [(HistoryRecordPayload, Bool)] = [
                (.connectionHistory(ConnectionHistoryEntry(hostID: UUID(), kind: .ssh)), false),
                (.connectionHistory(ConnectionHistoryEntry(hostID: UUID(), kind: .sftp)), true),
                (.device(DeviceRecord(id: UUID(), displayName: "Live legacy device")), false),
                (.device(DeviceRecord(id: UUID(), displayName: "Deleted legacy device")), true),
            ]
            let version = VaultVersion.baseline(writerID: UUID())
            let current = cases.map { HistoryEnvelope(key: $0.0.key, version: version, payload: $0.0) }
            _ = try HistorySyncPersistence(context: context).applyRemote(current)
            let oldRecords = try cases.map { payload, isDeleted in
                let oldPayload: VaultRecordPayload
                switch payload {
                case .connectionHistory(let value): oldPayload = .connectionHistory(value)
                case .device(let value): oldPayload = .device(value)
                }
                let envelope = VaultEnvelope(
                    key: oldPayload.key, version: version, isDeleted: isDeleted,
                    payload: isDeleted ? nil : oldPayload)
                return try VaultSyncCoordinator.makeRecord(
                    .init(envelope: envelope),
                    recordID: .init(recordName: envelope.key.recordName, zoneID: fixture.lifecycle.zoneID))
            }
            recordNames = Set(oldRecords.map(\.recordID.recordName))
            let scope = try #require(fixture.lifecycle.scope)
            savedScope = scope
            for name in recordNames {
                let row = PersistentCloudSyncRecordState(scope: scope, recordName: name)
                row.wasPresent = true
                row.legacyDeletion = try JSONEncoder().encode(version)
                context.insert(row)
            }
            try context.save()
            let replica = try #require(fixture.lifecycle.store.replica)
            let missing = try replica.missing(scope, [])
            #expect(recordNames.isDisjoint(with: missing.deleted))

            try fixture.receive(oldRecords, [])
            try fixture.receive([], oldRecords.map(\.recordID))
            #expect(try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 2)
            #expect(try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 2)
            #expect(fixture.remoteApplyCount == 0)
            #expect(fixture.batch(oldRecords.map { .deleteRecord($0.recordID) }) == nil)
            #expect(fixture.batch(oldRecords.map { .saveRecord($0.recordID) }) == nil)
            fixture.lifecycle.pause()
            fixture.network.nextEngine = LifecycleEngine()
            try await fixture.start()
            #expect(fixture.batch(oldRecords.map { .deleteRecord($0.recordID) }) == nil)
            #expect(
                try fixture.lifecycle.store.pendingChanges(scope).allSatisfy {
                    !recordNames.contains($0.recordName)
                })
            fixture.stop()
        }

        let scope = try #require(savedScope)
        let reopened = try TermindPersistence.makeContainer(url: url)
        let records = try VaultSyncJournal(context: reopened.mainContext).cloudRecords()
        let pending = try CloudSyncRecordStateStore(context: reopened.mainContext, scope: scope).pendingChanges(records)
        #expect(recordNames.isDisjoint(with: pending.map(\.recordName)))
    }

    @Test
    func ignoredVaultCopiesDoNotClearQuarantineOrSendOldDeletes() async throws {
        let fixture = try CloudSyncSafetyFixture(category: .vault)
        defer { fixture.stop() }
        try await fixture.start()
        let vaultZone = fixture.lifecycle.zoneID
        let wrongTypeID = CKRecord.ID(
            recordName: HistoryRecordKey(kind: .device, id: UUID()).recordName, zoneID: vaultZone)
        let wrongZoneID = CKRecord.ID(
            recordName: HistoryRecordKey(kind: .connectionHistory, id: UUID()).recordName,
            zoneID: .init(zoneName: ConnectionHistorySyncCoordinator.zoneName))
        let noncanonicalUUID = UUID().uuidString.uppercased()
        let noncanonicalID = CKRecord.ID(recordName: "v1/device/\(noncanonicalUUID)", zoneID: vaultZone)
        let queuedCanonicalID = CKRecord.ID(
            recordName: HistoryRecordKey(kind: .device, id: UUID()).recordName, zoneID: vaultZone)
        let records = [
            CKRecord(recordType: "DeviceItem", recordID: wrongTypeID),
            CKRecord(recordType: VaultSyncCoordinator.recordType, recordID: wrongZoneID),
            CKRecord(recordType: VaultSyncCoordinator.recordType, recordID: noncanonicalID),
        ]
        let safety = try fixture.safety()
        for record in records {
            try safety.quarantine(recordName: record.recordID.recordName, payloadData: Data([1]), reason: "Keep")
        }
        try safety.quarantine(recordName: queuedCanonicalID.recordName, payloadData: Data([2]), reason: "Obsolete")
        let scope = try #require(fixture.lifecycle.scope)
        let row = PersistentCloudSyncRecordState(scope: scope, recordName: queuedCanonicalID.recordName)
        row.legacyDeletion = try JSONEncoder().encode(VaultVersion.baseline(writerID: UUID()))
        fixture.container.mainContext.insert(row)
        try fixture.container.mainContext.save()

        try fixture.receive(records, [])
        try fixture.lifecycle.reconcilePendingChanges()

        #expect(
            try safety.blockedRecordNames()
                == Set(records.map(\.recordID.recordName) + [queuedCanonicalID.recordName]))
        let pending =
            records.map { CKSyncEngine.PendingRecordZoneChange.deleteRecord($0.recordID) }
            + [.deleteRecord(queuedCanonicalID)]
        #expect(fixture.batch(pending) == nil)
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

    @Test(arguments: SyncSafetyCategory.allCases)
    func version36MigrationPhysicallyDeletesConfirmedTombstonesAcrossEveryCategory(
        category: SyncSafetyCategory
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Migration.store")
        let tombstone = try Self.writeVersion36Tombstone(url: url, category: category)
        let scope: CloudSyncScope
        do {
            let fixture = try MigratedPhysicalDeletionFixture(category: category, url: url)
            try await fixture.start()
            scope = try #require(fixture.lifecycle.scope)
            #expect(
                try fixture.lifecycle.store.pendingChanges(scope)
                    == [tombstone])
            let id = CKRecord.ID(recordName: tombstone.recordName, zoneID: fixture.lifecycle.zoneID)
            let batch = try #require(fixture.batch([.deleteRecord(id)]))
            #expect(batch.recordsToSave.isEmpty)
            #expect(batch.recordIDsToDelete == [id])
            try fixture.sent(.init(savedRecords: [], failedRecordSaves: [], deletedRecordIDs: [id]))
            #expect(try fixture.lifecycle.store.pendingChanges(scope).isEmpty)
            let acknowledgedRecords = try fixture.cloudRecords()
            #expect(acknowledgedRecords.contains { $0.mutation == tombstone && !$0.needsUpload })
            fixture.stop()
        }

        let reopened = try TermindPersistence.makeContainer(url: url)
        let records = try Self.cloudRecords(category: category, context: reopened.mainContext)
        #expect(
            try CloudSyncRecordStateStore(context: reopened.mainContext, scope: scope).pendingChanges(records).isEmpty)
        var differentAccount = scope
        differentAccount.account = "another-account"
        #expect(
            try CloudSyncRecordStateStore(context: reopened.mainContext, scope: differentAccount).pendingChanges(
                records) == [tombstone])
    }

    private static func writeVersion36Tombstone(
        url: URL, category: SyncSafetyCategory
    ) throws -> CloudSyncMutation {
        let schema = Schema(versionedSchema: TermindSchemaV36.self)
        let configuration = ModelConfiguration("Termind", schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let version = VaultVersion.baseline(writerID: UUID())
        let recordName: String
        switch category {
        case .vault:
            let key = VaultRecordPayload.hostGroup(HostGroup(name: "Migrated")).key
            container.mainContext.insert(
                try PersistentVaultSyncEntry(
                    envelope: .init(key: key, version: version, isDeleted: true), needsUpload: false))
            recordName = key.recordName
        case .settings:
            let key = SettingsRecordPayload.sftp(SFTPPreferences()).key
            container.mainContext.insert(
                try PersistentAIConfigurationSyncEntry(
                    envelope: .init(key: key, version: version, isDeleted: true), needsUpload: false))
            recordName = key.recordName
        case .metrics:
            let payload = MetricsRecordPayload.selection(
                SyncedMetricsSelection(selection: MetricsSelection(id: UUID()), sortIndex: 0))
            container.mainContext.insert(
                try PersistentMetricsSyncEntry(
                    envelope: .init(key: payload.key, version: version, isDeleted: true), needsUpload: false))
            recordName = payload.key.recordName
        case .history, .device:
            let key = HistoryRecordKey(
                kind: category == .device ? .device : .connectionHistory, id: UUID())
            container.mainContext.insert(
                try PersistentHistorySyncEntry(
                    envelope: .init(key: key, version: version, isDeleted: true), needsUpload: false))
            recordName = key.recordName
        }
        try container.mainContext.save()
        return CloudSyncMutation(recordName: recordName, operation: .delete, version: version)
    }

    private static func cloudRecords(
        category: SyncSafetyCategory, context: ModelContext
    ) throws -> [CloudSyncJournalRecord] {
        switch category {
        case .vault: try VaultSyncJournal(context: context).cloudRecords()
        case .settings: try SettingsSyncJournal(context: context).cloudRecords()
        case .metrics: try MetricsSyncJournal(context: context).cloudRecords()
        case .history: try HistorySyncJournal(context: context, kind: .connectionHistory).cloudRecords()
        case .device: try HistorySyncJournal(context: context, kind: .device).cloudRecords()
        }
    }

    private static func assetDirectoryName(for category: SyncSafetyCategory) -> String? {
        switch category {
        case .vault: VaultSyncCoordinator.assetDirectoryName
        case .settings: SettingsSyncCoordinator.assetDirectoryName
        case .metrics: MetricsSyncCoordinator.assetDirectoryName
        case .history, .device: nil
        }
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

    private static func liveRecord(_ record: CKRecord, version: VaultVersion) throws -> CKRecord {
        switch record.recordType {
        case "VaultItem":
            var envelope = try VaultSyncCoordinator.envelope(from: record)
            envelope.version = version
            return try VaultSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        case "MetricsItem":
            var envelope = try MetricsSyncCoordinator.envelope(from: record)
            envelope.version = version
            return try MetricsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        case "ConnectionHistoryItem", "DeviceItem":
            var envelope = try HistoryRecordSyncCoordinator.envelope(from: record)
            envelope.version = version
            return try HistoryRecordSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        default:
            var envelope = try SettingsSyncCoordinator.envelope(from: record)
            envelope.version = version
            return try SettingsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: record.recordID)
        }
    }
}

@MainActor
private struct MigratedDeletionAdapter {
    var lifecycle: CloudSyncLifecycle
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch?
    var sent: (CloudSyncSentChanges) throws -> Void
    var cloudRecords: () throws -> [CloudSyncJournalRecord]
}

@MainActor
private final class MigratedPhysicalDeletionFixture {
    let container: ModelContainer
    let defaults: UserDefaults
    let defaultsName = "MigratedPhysicalDeletionTests.\(UUID())"
    let network: LifecycleNetwork
    private let adapter: MigratedDeletionAdapter

    var lifecycle: CloudSyncLifecycle { adapter.lifecycle }
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch? { adapter.batch }
    var sent: (CloudSyncSentChanges) throws -> Void { adapter.sent }
    var cloudRecords: () throws -> [CloudSyncJournalRecord] { adapter.cloudRecords }

    init(category: SyncSafetyCategory, url: URL) throws {
        container = try TermindPersistence.makeContainer(url: url)
        defaults = UserDefaults(suiteName: defaultsName)!
        let fixtureNetwork = LifecycleNetwork()
        network = fixtureNetwork
        for key in [
            SettingsKey.iCloudSyncEnabled, SettingsKey.vaultSyncEnabled,
            SettingsKey.settingsSyncEnabled, SettingsKey.metricsSyncEnabled, SettingsKey.historySyncEnabled,
        ] { defaults.set(true, forKey: key) }
        let context = container.mainContext
        switch category {
        case .vault:
            let journal = VaultSyncJournal(context: context)
            let coordinator = VaultSyncCoordinator(
                context: context, defaults: defaults, environmentIdentifier: "Test",
                makeTransport: { _, _ in fixtureNetwork.transport })
            adapter = MigratedDeletionAdapter(
                lifecycle: coordinator.lifecycle,
                batch: { coordinator.makeChangeBatch($0, engine: fixtureNetwork.nextEngine) },
                sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords)
        case .settings:
            let persistence = SettingsSyncPersistence(context: context, defaults: defaults)
            let journal = persistence.journal
            let secrets = AISecretStore(context: context, keychain: InMemorySecretStore(), defaults: defaults)
            let coordinator = SettingsSyncCoordinator(
                persistence: persistence, secrets: secrets, defaults: defaults, environmentIdentifier: "Test",
                makeTransport: { _, _ in fixtureNetwork.transport })
            adapter = MigratedDeletionAdapter(
                lifecycle: coordinator.lifecycle,
                batch: { coordinator.makeChangeBatch($0, engine: fixtureNetwork.nextEngine) },
                sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords)
        case .metrics:
            let persistence = MetricsSyncPersistence(context: context, defaults: defaults)
            let journal = persistence.journal
            let coordinator = MetricsSyncCoordinator(
                persistence: persistence, defaults: defaults, environmentIdentifier: "Test",
                makeTransport: { _, _ in fixtureNetwork.transport })
            adapter = MigratedDeletionAdapter(
                lifecycle: coordinator.lifecycle,
                batch: { coordinator.makeChangeBatch($0, engine: fixtureNetwork.nextEngine) },
                sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords)
        case .history, .device:
            let kind: HistoryRecordKind = category == .device ? .device : .connectionHistory
            let persistence = HistorySyncPersistence(context: context)
            try persistence.prepare()
            let journal = HistorySyncJournal(context: context, kind: kind)
            let coordinator = HistoryRecordSyncCoordinator(
                persistence: persistence, kind: kind, defaults: defaults, environmentIdentifier: "Test",
                makeTransport: { _, _ in fixtureNetwork.transport })
            adapter = MigratedDeletionAdapter(
                lifecycle: coordinator.lifecycle,
                batch: { coordinator.makeChangeBatch($0, engine: fixtureNetwork.nextEngine) },
                sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords)
        }
    }

    func start() async throws {
        lifecycle.start()
        await lifecycle.operation?.value
        #expect(lifecycle.isReadyToSend)
    }

    func stop() {
        lifecycle.pause()
        defaults.removePersistentDomain(forName: defaultsName)
    }
}

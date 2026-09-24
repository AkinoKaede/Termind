import CloudKit
import Foundation
import SwiftData
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct CloudSyncSafetyTests {
    @Test(arguments: SyncSafetyCategory.allCases)
    func fetchedWinnerClearsJournalQueueAndStaleBatchSnapshotAtEveryUploadBoundary(
        category: SyncSafetyCategory
    ) async throws {
        for useNewerRemote in [false, true] {
            let fixture = try CloudSyncSafetyFixture(category: category)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let staleSnapshot = [CKSyncEngine.PendingRecordZoneChange.saveRecord(id)]
            let fetched = useNewerRemote ? try fixture.newerRecord(id) : try #require(fixture.record(id))

            try fixture.receive([fetched], [])

            #expect(try !fixture.pendingNames().contains(id.recordName))
            #expect(!fixture.network.nextEngine.queued.contains(id.recordName))
            #expect(fixture.record(id) == nil)
            #expect(fixture.batch(staleSnapshot) == nil)
            try fixture.receive([fetched], [])
            #expect(try !fixture.pendingNames().contains(id.recordName))
            #expect(!fixture.network.nextEngine.queued.contains(id.recordName))
            fixture.stop()
        }
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func olderFetchedRecordCannotAcknowledgeTheCurrentLocalWinner(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]

        try fixture.receive([try fixture.olderRecord(id)], [])

        #expect(try fixture.pendingNames().contains(id.recordName))
        #expect(fixture.network.nextEngine.queued.contains(id.recordName))
        #expect(fixture.record(id) != nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func sameVersionDifferentPayloadCannotAcknowledgeTheCurrentLocalWinner(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]

        try fixture.receive([try fixture.sameVersionLosingRecord(id)], [])

        #expect(try fixture.pendingNames().contains(id.recordName))
        #expect(fixture.network.nextEngine.queued.contains(id.recordName))
        #expect(fixture.record(id) != nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func everyCoordinatorDeduplicatesRestoredQueueEntries(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let pending = (0...CloudSyncLifecycle.maximumRecordsPerRequest).map { index in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                fixture.recordIDs[index % fixture.recordIDs.count]
            )
        }

        let batch = try #require(fixture.batch(pending))

        #expect(Set(batch.recordsToSave.map(\.recordID)) == Set(fixture.recordIDs))
        #expect(batch.recordIDsToDelete.isEmpty)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func unsupportedRecordIsFencedAtJournalBatchAndProviderWithoutBlockingOtherRecords(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let future = try fixture.futureRecord()
        let blockedID = fixture.recordIDs[0]
        let healthyID = fixture.recordIDs[1]
        #expect(fixture.network.nextEngine.queued.contains(blockedID.recordName))
        try fixture.lifecycle.beginFetch()
        try fixture.receive([future], [])
        try fixture.lifecycle.finishFetch()
        try fixture.lifecycle.updateUpToDateStatus()
        let safety = try fixture.safety()
        let isolated = try #require(try safety.entry(recordName: blockedID.recordName))
        try CloudSyncSafetyFixture.expectPreserved(future, in: isolated.payloadData)
        #expect(isolated.reasonCode == CloudSyncQuarantineReason.unsupportedFormat.rawValue)
        #expect(try fixture.pendingNames() == Set(fixture.recordIDs.map(\.recordName)))
        #expect(!fixture.network.nextEngine.queued.contains(blockedID.recordName))
        #expect(fixture.lifecycle.status == .partiallyBlocked(pendingCount: 1, blockedCount: 1, requiresUpdate: true))
        let batch = try #require(
            fixture.batch([
                .saveRecord(blockedID), .saveRecord(healthyID), .deleteRecord(blockedID), .deleteRecord(healthyID),
            ]))
        #expect(batch.recordsToSave.map(\.recordID) == [healthyID])
        #expect(batch.recordIDsToDelete.isEmpty)
        #expect(fixture.record(blockedID) == nil)
        #expect(fixture.record(healthyID) != nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func serverConflictUsesTheSameQuarantineAndRetryCannotBypassIt(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let future = try fixture.futureRecord()
        try fixture.conflict(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: future]))
        let blockedID = fixture.recordIDs[0]
        #expect(try fixture.safety().isUploadBlocked(recordName: blockedID.recordName))
        fixture.lifecycle.retry()
        await fixture.lifecycle.operation?.value
        #expect(fixture.record(blockedID) == nil)
        fixture.lifecycle.pause()
        fixture.network.nextEngine = LifecycleEngine()
        try await fixture.start()
        #expect(fixture.record(blockedID) == nil)
        #expect(fixture.record(fixture.recordIDs[1]) != nil)
        #expect(try fixture.pendingNames().contains(blockedID.recordName))
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func physicalDeletionCancelsIntentAndReplayedDataCannotBypassQuarantine(
        category: SyncSafetyCategory
    ) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let id = fixture.recordIDs[0]
        let supported = try #require(fixture.record(id))
        try fixture.receive([fixture.futureRecord()], [])
        try fixture.markTombstone()
        try fixture.receive([], [id])
        #expect(fixture.record(id) == nil)
        #expect(fixture.batch([.saveRecord(id), .deleteRecord(id)]) == nil)
        #expect(try !fixture.pendingNames().contains(id.recordName))
        try fixture.receive([supported], [])
        #expect(try !fixture.safety().isUploadBlocked(recordName: id.recordName))
        #expect(!fixture.network.nextEngine.queued.contains(id.recordName))
        #expect(fixture.record(id) == nil)
        let outgoing = try #require(fixture.batch([.deleteRecord(id)]))
        #expect(outgoing.recordIDsToDelete == [id])
        #expect(outgoing.recordsToSave.isEmpty)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func failedMergeRollsBackBothUnblockAndJournalMutation(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let future = try fixture.futureRecord()
        try fixture.receive([future], [])
        let safety = try fixture.safety()
        #expect(throws: CocoaError.self) { try fixture.failingMerge(safety) }
        let row = try #require(try safety.entry(recordName: fixture.recordIDs[0].recordName))
        try CloudSyncSafetyFixture.expectPreserved(future, in: row.payloadData)
        #expect(try fixture.pendingNames() == Set(fixture.recordIDs.map(\.recordName)))
        #expect(fixture.record(fixture.recordIDs[0]) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func malformedPayloadAlsoBlocksUploadsWithoutClaimingAnUpgradeWillFixIt(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let record = try #require(fixture.record(fixture.recordIDs[0]))
        let malformed = Data([0xff])
        let native = category == .history || category == .device
        if native {
            record["writerID"] = NSNumber(value: 42)
        } else {
            CloudSyncSafetyFixture.setPayload(malformed, in: record)
        }
        try fixture.receive([record], [])
        let row = try #require(try fixture.safety().entry(recordName: record.recordID.recordName))
        #expect(row.reasonCode == (native ? CloudSyncQuarantineReason.invalidRecord : .unreadablePayload).rawValue)
        try CloudSyncSafetyFixture.expectPreserved(record, in: row.payloadData)
        try fixture.lifecycle.updateUpToDateStatus()
        #expect(fixture.lifecycle.status == .partiallyBlocked(pendingCount: 1, blockedCount: 1, requiresUpdate: false))
        #expect(fixture.record(record.recordID) == nil)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func unreadableRepresentationWinsForTheSameIDInEitherBatchOrder(category: SyncSafetyCategory) async throws {
        for unreadableFirst in [false, true] {
            let fixture = try CloudSyncSafetyFixture(category: category)
            try await fixture.start()
            let id = fixture.recordIDs[0]
            let supported = try #require(fixture.record(id))
            let future = try fixture.futureRecord()
            let records = unreadableFirst ? [future, supported] : [supported, future]

            try fixture.receive(records, [])

            #expect(try fixture.safety().isUploadBlocked(recordName: id.recordName))
            #expect(fixture.record(id) == nil)
            #expect(fixture.remoteApplyCount == 0)
            fixture.stop()
        }
    }

    @Test
    func quarantinePersistenceFailureEscapesTheSharedDecoder() throws {
        let record = CKRecord(recordType: "Test")
        var logged = false

        #expect(throws: CocoaError.self) {
            _ = try decodeCloudSyncRecords(
                [record], included: { _ in true },
                decode: { _ -> String in throw CKError(.badDatabase) },
                quarantine: { _, _ in throw CocoaError(.fileWriteUnknown) },
                logFailure: { _ in logged = true })
        }
        #expect(logged)
    }

    @Test(arguments: SyncSafetyCategory.allCases)
    func newRecordTypesAreIgnoredButCannotBypassAConflictForAKnownID(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let source = try #require(fixture.record(fixture.recordIDs[0]))
        let unknown = CKRecord(recordType: "FutureFeature", recordID: source.recordID)
        for key in source.allKeys() { unknown[key] = source[key] }
        try fixture.receive([unknown], [])
        #expect(try fixture.safety().blockedRecordNames().isEmpty)
        #expect(fixture.remoteApplyCount == 0)
        try fixture.conflict(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: unknown]))
        #expect(try fixture.safety().isUploadBlocked(recordName: unknown.recordID.recordName))
        #expect(fixture.record(unknown.recordID) == nil)
        #expect(fixture.remoteApplyCount == 0)
    }
}

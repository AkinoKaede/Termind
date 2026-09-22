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
    func everyCoordinatorUsesTheSharedCloudKitRequestLimit(category: SyncSafetyCategory) async throws {
        let fixture = try CloudSyncSafetyFixture(category: category)
        defer { fixture.stop() }
        try await fixture.start()
        let pending = (0...CloudSyncLifecycle.maximumRecordsPerRequest).map { index in
            CKSyncEngine.PendingRecordZoneChange.saveRecord(
                fixture.recordIDs[index % fixture.recordIDs.count]
            )
        }

        let batch = try #require(fixture.batch(pending))

        #expect(batch.recordsToSave.count == CloudSyncLifecycle.maximumRecordsPerRequest)
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
        #expect(isolated.payloadData == future["payload"] as? Data)
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
    func tombstoneAndPhysicalRecreationStayBlockedUntilSupportedRemoteDataCommits(
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
        #expect(try fixture.pendingNames().contains(id.recordName))
        try fixture.receive([supported], [])
        #expect(try !fixture.safety().isUploadBlocked(recordName: id.recordName))
        #expect(fixture.network.nextEngine.queued.contains(id.recordName))
        let outgoing = try #require(fixture.record(id))
        let data = try #require(outgoing["payload"] as? Data)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["isDeleted"] as? Bool == true)
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
        #expect(row.payloadData == future["payload"] as? Data)
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
        CloudSyncSafetyFixture.setPayload(malformed, in: record)
        try fixture.receive([record], [])
        let row = try #require(try fixture.safety().entry(recordName: record.recordID.recordName))
        #expect(row.reasonCode == CloudSyncQuarantineReason.unreadablePayload.rawValue)
        #expect(row.payloadData == malformed)
        try fixture.lifecycle.updateUpToDateStatus()
        #expect(fixture.lifecycle.status == .partiallyBlocked(pendingCount: 1, blockedCount: 1, requiresUpdate: false))
        #expect(fixture.record(record.recordID) == nil)
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
        try fixture.conflict(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: unknown]))
        #expect(try fixture.safety().isUploadBlocked(recordName: unknown.recordID.recordName))
        #expect(fixture.record(unknown.recordID) == nil)
    }
}

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

@Suite @MainActor
struct HistorySyncTests {
    @Test func newCloudRecordsUseNativeFieldsAndOptionalRemovalRoundTrips() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let event = try #require(fixture.record(fixture.event.key))
        #expect(event.recordType == "ConnectionHistoryItem")
        #expect(event["payload"] == nil)
        #expect(event["payloadAsset"] == nil)
        #expect(event["hostID"] as? String != nil)
        #expect(event["connectedAt"] as? Date != nil)
        #expect(try HistorySyncCoordinator.envelope(from: event) == fixture.event)
        let device = try #require(fixture.record(fixture.device.key))
        #expect(device.recordType == "DeviceItem")
        #expect(device["displayName"] as? String == "Mac")
        #expect(device["payload"] == nil)
        #expect(try HistorySyncCoordinator.envelope(from: device) == fixture.device)
        event["endedAt"] = NSDate()
        try HistoryCloudRecordV1.write(fixture.event, into: event)
        #expect(event["endedAt"] == nil)
        event["connectionKind"] = "future-protocol" as NSString
        #expect(throws: (any Error).self) { try HistorySyncCoordinator.envelope(from: event) }
    }

    @Test func overlappingAutomaticImportWaitsWithoutReportingAPersistentStoreFailure() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        var entered = false
        fixture.source.nextEngine.fetchBody = {
            try fixture.coordinator.legacyImporter.beginFetch()
            entered = true
        }
        fixture.coordinator.start()
        while !entered { await Task.yield() }
        #expect(!fixture.coordinator.lifecycle.isReadyToSend)
        #expect(fixture.record(fixture.device.key) == nil)
        if case .failed = fixture.coordinator.status { Issue.record("An overlapping read is not a store failure") }
        try fixture.coordinator.legacyImporter.finishFetch(succeeded: true)
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.coordinator.lifecycle.isReadyToSend)
        #expect(fixture.record(fixture.device.key) != nil)
    }

    @Test func initialSignInAndLateCancellationDoNotProduceFailure() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        fixture.coordinator.legacyImporter.handleAccountChange(
            .signIn(currentUser: CKRecord.ID(recordName: "current-user")))
        #expect(fixture.coordinator.legacyImporter.ready(for: fixture.scope))
        let previous = fixture.coordinator.status
        fixture.coordinator.lifecycle.failClosed(CancellationError())
        #expect(fixture.coordinator.status == previous)
        #expect(fixture.coordinator.lifecycle.isReadyToSend)
        fixture.coordinator.pause()
        fixture.coordinator.lifecycle.failClosed(CKError(.operationCancelled))
        #expect(fixture.coordinator.status == .paused)
    }

    @Test func syncFailuresUseApplicationLoggingWithoutRecordPayloads() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logging = LaunchFileLogService(directory: directory, defaults: fixture.defaults)
        try logging.setSaving(true)
        fixture.coordinator.configureLogging(logging)
        try await fixture.start()
        fixture.coordinator.lifecycle.failClosed(
            NSError(
                domain: "test-sync", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "private-host.example"]))
        let file = try #require(logging.files().first)
        let content = try String(contentsOf: logging.exportURL(for: file.id), encoding: .utf8)
        #expect(content.contains("cloud.sync.failed"))
        #expect(content.contains("stage=lifecycle"))
        #expect(content.contains("zone=TermindConnectionHistoryV1"))
        #expect(content.contains("error-code=42"))
        #expect(!content.contains("private-host.example"))
    }

    @Test func deviceRemainsEligibleWithHistoryAndLegacyVaultDisabled() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        fixture.defaults.set(false, forKey: SettingsKey.historySyncEnabled)
        try await fixture.start()
        #expect(fixture.coordinator.historyStatus == .paused)
        #expect(fixture.record(fixture.event.key) == nil)
        #expect(fixture.record(fixture.device.key) != nil)
        #expect(!fixture.source.steps.contains("zone"))
        #expect(fixture.source.nextEngine.sendCount == 0)
        #expect(fixture.source.nextEngine.queued.isEmpty)

        fixture.coordinator.setEnabled(true)
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.event.key) != nil)
        #expect(fixture.source.serializations.allSatisfy { $0 == nil })
        #expect(fixture.destination.serializations.allSatisfy { $0 == nil })
        fixture.defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        fixture.coordinator.start()
        #expect(fixture.record(fixture.device.key) == nil)
        #expect(fixture.coordinator.legacyImporter.engine == nil)
    }

    @Test func legacyChangesKeepIDsVersionsAndNeverWriteBack() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        var event = fixture.event
        guard case .connectionHistory(var entry) = event.payload else { return }
        entry.endedAt = Date(timeIntervalSince1970: 200)
        event.payload = .connectionHistory(entry)
        event.version.counter += 1
        var device = fixture.device
        device.payload = .device(DeviceRecord(id: device.key.id, displayName: "Renamed old Mac"))
        device.version.counter += 1
        try fixture.coordinator.legacyImporter.receive([fixture.legacyRecord(event), fixture.legacyRecord(device)])
        try fixture.coordinator.legacyImporter.receive([fixture.legacyRecord(event), fixture.legacyRecord(device)])
        #expect(try fixture.persistence.journal.envelope(for: event.key) == event)
        #expect(try fixture.persistence.journal.envelope(for: device.key) == device)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 1)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentVaultSyncEntry>()) == 0)
        #expect(
            try fixture.persistence.journal.outgoingEntry(for: event.key, scope: fixture.scope)?.systemFieldsData == nil
        )
        #expect(fixture.source.nextEngine.sendCount == 0)

        var deleted = event
        deleted.isDeleted = true
        deleted.payload = nil
        deleted.version.counter += 1
        _ = try fixture.persistence.applyRemote([deleted], importingLegacy: true)
        event.version.counter += 100
        try fixture.coordinator.legacyImporter.receive([fixture.legacyRecord(event)])
        #expect(try fixture.persistence.journal.envelope(for: event.key)?.isDeleted == true)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
    }

    @Test func unsupportedSourceFencesDestinationUntilSupportedReplayCommits() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let supported = try fixture.legacyRecord(fixture.event)
        let future = try fixture.legacyRecord(fixture.event)
        var json = try #require(
            JSONSerialization.jsonObject(with: VaultSyncCoordinator.payloadData(from: future)) as? [String: Any])
        json["formatVersion"] = 2
        CloudSyncSafetyFixture.setPayload(try JSONSerialization.data(withJSONObject: json), in: future)
        future["formatVersion"] = NSNumber(value: 2)
        try fixture.coordinator.legacyImporter.receive([future])
        let sourceSafety = CloudSyncSafetyStore(context: fixture.context, scope: fixture.scope.historyImportScope)
        #expect(try sourceSafety.isUploadBlocked(recordName: fixture.event.key.recordName))
        #expect(fixture.record(fixture.event.key) == nil)
        #expect(fixture.record(fixture.device.key) != nil)
        fixture.coordinator.retry()
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.event.key) == nil)
        try fixture.coordinator.legacyImporter.receive([supported])
        #expect(try !sourceSafety.isUploadBlocked(recordName: fixture.event.key.recordName))
        #expect(fixture.record(fixture.event.key) != nil)
    }

    @Test func sourceQuarantineUpdatesAnAlreadySuccessfulStatusWithoutNewUploads() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        try fixture.persistence.journal.markUploaded(fixture.event.key, version: fixture.event.version)
        try fixture.persistence.journal.markUploaded(fixture.device.key, version: fixture.device.version)
        try fixture.context.save()
        try fixture.coordinator.lifecycle.updateUpToDateStatus()
        let initialSync = try fixture.persistence.journal.state().lastSuccessfulSync
        #expect(fixture.coordinator.historyStatus == .upToDate(lastSuccessfulSync: initialSync))

        let future = try fixture.legacyRecord(fixture.event)
        var json = try #require(
            JSONSerialization.jsonObject(with: VaultSyncCoordinator.payloadData(from: future)) as? [String: Any])
        json["formatVersion"] = 2
        CloudSyncSafetyFixture.setPayload(try JSONSerialization.data(withJSONObject: json), in: future)
        future["formatVersion"] = NSNumber(value: 2)
        try fixture.coordinator.legacyImporter.beginFetch()
        try fixture.coordinator.legacyImporter.receive([future])
        try fixture.coordinator.legacyImporter.finishFetch(succeeded: true)
        #expect(
            fixture.coordinator.historyStatus
                == .partiallyBlocked(pendingCount: 0, blockedCount: 1, requiresUpdate: true))
        #expect(fixture.coordinator.deviceStatus == .upToDate(lastSuccessfulSync: initialSync))

        try fixture.coordinator.legacyImporter.beginFetch()
        try fixture.coordinator.legacyImporter.receive([fixture.legacyRecord(fixture.event)])
        try fixture.coordinator.legacyImporter.finishFetch(succeeded: true)
        let resumedSync = try fixture.persistence.journal.state().lastSuccessfulSync
        #expect(fixture.coordinator.historyStatus == .upToDate(lastSuccessfulSync: resumedSync))
    }

    @Test func unrelatedRecordTypeInLegacyZoneDoesNotQuarantineOrBlockHistory() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let record = CKRecord(
            recordType: "FutureVaultFeature",
            recordID: CKRecord.ID(
                recordName: "v1/futureFeature/\(UUID().uuidString.lowercased())",
                zoneID: CKRecordZone.ID(zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)))
        try fixture.coordinator.legacyImporter.receive([record])
        let sourceSafety = CloudSyncSafetyStore(context: fixture.context, scope: fixture.scope.historyImportScope)
        #expect(try sourceSafety.blockedRecordNames().isEmpty)
        #expect(try fixture.persistence.journal.envelope(for: fixture.event.key) == fixture.event)
    }

    @Test func initialImporterFailurePreventsAllDestinationUploadsAndRetryRecovers() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.source.nextEngine.fetchBody = { throw CocoaError(.fileReadUnknown) }
        fixture.coordinator.start()
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.device.key) == nil)
        #expect(fixture.destination.nextEngine.sendCount == 0)
        #expect(fixture.coordinator.legacyImporter.engine == nil)
        fixture.source.nextEngine = LifecycleEngine()
        fixture.destination.nextEngine = LifecycleEngine()
        fixture.coordinator.retry()
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.device.key) != nil)
    }

    @Test func historyPreferenceInheritsLegacySelectionOnlyOnce() throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.defaults.removeObject(forKey: SettingsKey.historySyncEnabled)
        fixture.defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        SettingsKey.migrateSyncPreferences(in: fixture.defaults)
        #expect(!fixture.defaults.bool(forKey: SettingsKey.historySyncEnabled))
        fixture.defaults.set(true, forKey: SettingsKey.historySyncEnabled)
        SettingsKey.migrateSyncPreferences(in: fixture.defaults)
        #expect(fixture.defaults.bool(forKey: SettingsKey.historySyncEnabled))
    }

    @Test func bootstrapFailureRollsBackAndReplayPreservesLegacyQuarantine() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let payload = VaultRecordPayload.device(DeviceRecord(id: UUID(), displayName: "Legacy"))
        let legacy = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let row = try PersistentVaultSyncEntry(envelope: legacy, needsUpload: true)
        row.systemFieldsData = Data([1, 2, 3])
        context.insert(row)
        context.insert(PersistentDeviceRecord(DeviceRecord(id: payload.key.id, displayName: "Legacy")))
        context.insert(
            PersistentVaultSyncQuarantine(recordName: payload.key.recordName, payloadData: Data([9]), reason: "Future"))
        try context.save()
        let persistence = HistorySyncPersistence(context: context)
        #expect(throws: (any Error).self) {
            _ = try persistence.applyRemote([], beforeSave: { throw CocoaError(.fileWriteUnknown) })
        }
        #expect(try context.fetchCount(FetchDescriptor<PersistentHistorySyncEntry>()) == 0)
        try persistence.prepare()
        try persistence.prepare()
        let migrated = try #require(context.fetch(FetchDescriptor<PersistentHistorySyncEntry>()).first)
        #expect(migrated.systemFieldsData == nil)
        #expect(migrated.envelope?.version == legacy.version)
        #expect(migrated.needsUpload)
        let scope = CloudSyncScope(
            container: HistorySyncCoordinator.containerIdentifier, environment: "Test", account: "current-user",
            zone: HistorySyncCoordinator.zoneName, owner: CKCurrentUserDefaultName)
        try persistence.journal.importLegacyQuarantine(into: scope)
        try context.save()
        #expect(
            try CloudSyncSafetyStore(context: context, scope: scope.historyImportScope).isUploadBlocked(
                recordName: legacy.key.recordName))
        #expect(try context.fetchCount(FetchDescriptor<PersistentHistorySyncEntry>()) == 1)
    }
}

@MainActor
private final class HistoryFixture {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let defaults: UserDefaults
    let suite = "HistorySyncTests.\(UUID())"
    let source = LifecycleNetwork()
    let destination = LifecycleNetwork()
    let persistence: HistorySyncPersistence
    let coordinator: HistorySyncCoordinator
    let event: HistoryEnvelope
    let device: HistoryEnvelope
    var scope: CloudSyncScope {
        CloudSyncScope(
            container: HistorySyncCoordinator.containerIdentifier, environment: "Test", account: "current-user",
            zone: HistorySyncCoordinator.zoneName, owner: CKCurrentUserDefaultName)
    }
    init() throws {
        container = try TermindPersistence.makeContainer(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: SettingsKey.iCloudSyncEnabled)
        defaults.set(true, forKey: SettingsKey.historySyncEnabled)
        persistence = HistorySyncPersistence(context: container.mainContext)
        let devicePayload = HistoryRecordPayload.device(DeviceRecord(id: UUID(), displayName: "Mac"))
        let eventPayload = HistoryRecordPayload.connectionHistory(ConnectionHistoryEntry(hostID: UUID(), kind: .ssh))
        let version = VaultVersion(modifiedAt: Date(timeIntervalSince1970: 100), counter: 1, writerID: UUID())
        event = HistoryEnvelope(key: eventPayload.key, version: version, payload: eventPayload)
        device = HistoryEnvelope(key: devicePayload.key, version: version, payload: devicePayload)
        _ = try persistence.applyRemote([event, device], importingLegacy: true)
        let source = source
        let destination = destination
        coordinator = HistorySyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in destination.transport }, makeLegacyTransport: { _, _ in source.transport })
    }
    func start() async throws {
        coordinator.start()
        await coordinator.lifecycle.operation?.value
        #expect(coordinator.lifecycle.isReadyToSend)
    }
    func stop() {
        coordinator.pause()
        defaults.removePersistentDomain(forName: suite)
    }
    func record(_ key: HistoryRecordKey) -> CKRecord? {
        coordinator.recordToSave(
            CKRecord.ID(recordName: key.recordName, zoneID: coordinator.lifecycle.zoneID),
            engine: destination.nextEngine)
    }
    func legacyRecord(_ envelope: HistoryEnvelope) throws -> CKRecord {
        try VaultSyncCoordinator.makeRecord(
            VaultOutgoingEntry(envelope: envelope.legacyEnvelope),
            recordID: CKRecord.ID(
                recordName: envelope.key.recordName,
                zoneID: CKRecordZone.ID(zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)))
    }
}

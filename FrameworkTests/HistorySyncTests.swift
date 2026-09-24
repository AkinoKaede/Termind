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
        #expect(try HistoryRecordSyncCoordinator.envelope(from: event) == fixture.event)
        let device = try #require(fixture.record(fixture.device.key))
        #expect(device.recordType == "DeviceItem")
        #expect(device["displayName"] as? String == "Mac")
        #expect(device["payload"] == nil)
        #expect(try HistoryRecordSyncCoordinator.envelope(from: device) == fixture.device)
        event["endedAt"] = NSDate()
        try HistoryCloudRecordV1.write(fixture.event, into: event)
        #expect(event["endedAt"] == nil)
        event["connectionKind"] = "future-protocol" as NSString
        #expect(throws: (any Error).self) { try HistoryRecordSyncCoordinator.envelope(from: event) }
    }

    @Test func lateCancellationDoesNotProduceFailure() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
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

    @Test func deviceRemainsEligibleWithHistoryAndVaultDisabled() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        fixture.defaults.set(false, forKey: SettingsKey.historySyncEnabled)
        try await fixture.start()
        #expect(fixture.connectionSync.status == .paused)
        #expect(fixture.record(fixture.event.key) == nil)
        #expect(fixture.record(fixture.device.key) != nil)

        fixture.coordinator.setEnabled(true)
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.event.key) != nil)
        #expect(fixture.destination.serializations.allSatisfy { $0 == nil })
        fixture.defaults.set(false, forKey: SettingsKey.iCloudSyncEnabled)
        fixture.coordinator.start()
        fixture.deviceSync.start()
        #expect(fixture.record(fixture.device.key) == nil)
    }

    @Test func deletedEventsCannotBeRevivedByLaterUpdates() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        var deleted = fixture.event
        deleted.isDeleted = true
        deleted.payload = nil
        deleted.version.counter += 1
        _ = try fixture.persistence.applyRemote([deleted])
        var delayed = fixture.event
        delayed.version.counter += 100
        _ = try fixture.persistence.applyRemote([delayed])
        #expect(try fixture.persistence.journal.envelope(for: delayed.key)?.isDeleted == true)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 0)
        #expect(try fixture.context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 1)
        #expect(try fixture.persistence.journal.pendingEnvelopes().contains { $0.key == deleted.key })
    }

    @Test func retentionTombstoneCreatedDuringFetchRemainsPending() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        for index in 0..<ConnectionHistoryModel.limit {
            fixture.context.insert(
                PersistentConnectionHistoryEntry(
                    ConnectionHistoryEntry(
                        hostID: UUID(), kind: .ssh,
                        connectedAt: Date(timeIntervalSince1970: TimeInterval(index + 1)))))
        }
        try fixture.context.save()
        let entry = ConnectionHistoryEntry(
            hostID: UUID(), kind: .ssh, connectedAt: Date(timeIntervalSince1970: 0))
        let envelope = HistoryEnvelope(
            key: HistoryRecordKey(kind: .connectionHistory, id: entry.id),
            version: VaultVersion(modifiedAt: Date(timeIntervalSince1970: 200), counter: 1, writerID: UUID()),
            payload: .connectionHistory(entry))
        let record = try HistoryRecordSyncCoordinator.makeRecord(
            .init(envelope: envelope),
            recordID: .init(recordName: envelope.key.recordName, zoneID: fixture.coordinator.lifecycle.zoneID))

        try fixture.coordinator.receiveRemoteRecords([record])

        let retainedEnvelope = try fixture.persistence.journal.envelope(for: envelope.key)
        let retained = try #require(retainedEnvelope)
        #expect(retained.isDeleted)
        #expect(retained.version > envelope.version)
        #expect(try fixture.persistence.journal.pendingEnvelopes().contains { $0.key == envelope.key })
        #expect(fixture.record(envelope.key) == nil)
        #expect(
            fixture.destination.nextEngine.deleteRecordNames(in: fixture.coordinator.lifecycle.zoneID)
                .contains(envelope.key.recordName))
    }

    @Test func historyIgnoresRecordsAndRestrictionsFromRetiredVaultImporter() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        var retiredScope = fixture.scope
        retiredScope.zone = VaultSyncCoordinator.zoneName
        retiredScope.consumer = "history-legacy-import"
        try CloudSyncSafetyStore(context: fixture.context, scope: retiredScope).quarantine(
            recordName: fixture.event.key.recordName, payloadData: Data([9]),
            reason: "Retired source", reasonCode: .unsupportedFormat)
        try fixture.context.save()
        try await fixture.start()
        let record = try #require(fixture.record(fixture.event.key))
        let oldRecord = CKRecord(
            recordType: "VaultItem",
            recordID: .init(
                recordName: record.recordID.recordName,
                zoneID: .init(zoneName: VaultSyncCoordinator.zoneName, ownerName: CKCurrentUserDefaultName)))
        try fixture.coordinator.receiveRemoteRecords([oldRecord])
        #expect(fixture.record(fixture.event.key) != nil)
        #expect(fixture.record(fixture.device.key) != nil)
        #expect(!TermindSchemaV36.models.contains { $0 == PersistentHistoryImportState.self })
        #expect(try fixture.coordinator.lifecycle.store.safety.blockedRecordNames(fixture.scope).isEmpty)
        #expect(try fixture.persistence.journal.envelope(for: fixture.event.key) == fixture.event)
    }

    @Test func initialHistoryFetchFailurePreventsUploadsAndRetryRecovers() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.destination.nextEngine.fetchBody = { throw CocoaError(.fileReadUnknown) }
        fixture.coordinator.start()
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.event.key) == nil)
        #expect(fixture.destination.nextEngine.sendCount == 0)
        fixture.destination.nextEngine = LifecycleEngine()
        fixture.coordinator.retry()
        await fixture.coordinator.lifecycle.operation?.value
        #expect(fixture.record(fixture.event.key) != nil)
    }

    @Test func historyPreferencesDoNotInheritRetiredVaultSelectionOrEnvironment() throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        fixture.defaults.removeObject(forKey: SettingsKey.historySyncEnabled)
        fixture.defaults.set(false, forKey: SettingsKey.vaultSyncEnabled)
        fixture.defaults.set("Retired", forKey: SettingsKey.vaultSyncEnvironment)
        SettingsKey.migrateSyncPreferences(in: fixture.defaults)
        #expect(fixture.defaults.object(forKey: SettingsKey.historySyncEnabled) == nil)
        #expect(fixture.defaults.object(forKey: SettingsKey.historySyncEnvironment) == nil)
        fixture.defaults.set(false, forKey: SettingsKey.historySyncEnabled)
        SettingsKey.migrateSyncPreferences(in: fixture.defaults)
        #expect(!fixture.defaults.bool(forKey: SettingsKey.historySyncEnabled))
    }

    @Test func coordinatorsKeepSeparateEnginesJournalsAndRestrictionsInTheDeployedZone() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        #expect(ConnectionHistorySyncCoordinator.zoneName == "TermindConnectionHistoryV1")
        #expect(DeviceSyncCoordinator.zoneName == ConnectionHistorySyncCoordinator.zoneName)
        #expect(DeviceSyncCoordinator.subscriptionID != ConnectionHistorySyncCoordinator.subscriptionID)
        let historyScope = try #require(fixture.coordinator.lifecycle.scope)
        let deviceScope = try #require(fixture.deviceSync.core.lifecycle.scope)
        #expect(historyScope != deviceScope)
        let historyState = try HistorySyncJournal(context: fixture.context, kind: .connectionHistory).state()
        let deviceState = try HistorySyncJournal(context: fixture.context, kind: .device).state()
        #expect(historyState.key != deviceState.key)
        historyState.engineStateData = Data([1])
        deviceState.engineStateData = Data([2])
        try fixture.context.save()
        let futureDevice = try #require(fixture.record(fixture.device.key))
        futureDevice["formatVersion"] = NSNumber(value: 99)
        try fixture.deviceSync.core.receiveRemoteRecords([futureDevice])
        #expect(fixture.record(fixture.device.key) == nil)
        #expect(fixture.record(fixture.event.key) != nil)
        fixture.deviceSync.core.lifecycle.failClosed(CocoaError(.fileReadUnknown))
        #expect(fixture.coordinator.lifecycle.isReadyToSend)
        try HistorySyncJournal(context: fixture.context, kind: .device).resetForZone()
        #expect(historyState.engineStateData == Data([1]))
        #expect(deviceState.engineStateData == nil)
        fixture.connectionSync.setEnabled(false)
        #expect(fixture.connectionSync.status == .paused)
    }

    @Test func freshInstallReadsExistingCloudRecordsWithHistoryArrivingBeforeDevice() async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let deviceID = UUID()
        let entry = ConnectionHistoryEntry(hostID: UUID(), kind: .ssh, sourceDeviceID: deviceID)
        let version = VaultVersion.baseline(writerID: UUID())
        let event = HistoryEnvelope(
            key: .init(kind: .connectionHistory, id: entry.id), version: version,
            payload: .connectionHistory(entry))
        let device = HistoryEnvelope(
            key: .init(kind: .device, id: deviceID), version: version,
            payload: .device(DeviceRecord(id: deviceID, displayName: "Retired Mac")))
        let devices = DeviceDirectoryModel(
            repository: SwiftDataDeviceDirectoryRepository(context: fixture.context),
            currentDeviceID: UUID(), currentDeviceName: "New Mac")
        fixture.deviceSync.didApplyRemote = { _ in devices.reload() }
        let zone = CKRecordZone.ID(zoneName: "TermindConnectionHistoryV1", ownerName: CKCurrentUserDefaultName)
        let eventRecord = try HistoryRecordSyncCoordinator.makeRecord(
            .init(envelope: event),
            recordID: .init(recordName: event.key.recordName, zoneID: zone))
        let deviceRecord = try HistoryRecordSyncCoordinator.makeRecord(
            .init(envelope: device),
            recordID: .init(recordName: device.key.recordName, zoneID: zone))
        try fixture.coordinator.receiveRemoteRecords([eventRecord])
        #expect(try fixture.persistence.journal.envelope(for: event.key) == event)
        #expect(devices.name(for: deviceID) == nil)
        try fixture.deviceSync.core.receiveRemoteRecords([deviceRecord])
        #expect(devices.name(for: deviceID) == "Retired Mac")
        #expect(try fixture.persistence.journal.envelope(for: event.key) == event)
        // Neither owner consumes the other category even though CloudKit fetches the same zone.
        try fixture.coordinator.receiveRemoteRecords([deviceRecord])
        try fixture.deviceSync.core.receiveRemoteRecords([eventRecord])
        #expect(try fixture.persistence.journal.envelope(for: event.key) == event)
    }

    @Test(arguments: [false, true])
    func missingDeviceProjectionIsRestoredWithoutChangingItsJournalVersion(replay: Bool) async throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        try await fixture.start()
        let record = try #require(fixture.record(fixture.device.key))
        for row in try fixture.context.fetch(FetchDescriptor<PersistentDeviceRecord>()) {
            fixture.context.delete(row)
        }
        try fixture.context.save()
        if replay {
            try fixture.deviceSync.core.receiveRemoteRecords([record])
        } else {
            try fixture.persistence.prepare()
        }
        #expect(
            try fixture.context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map(\.value)
                == [DeviceRecord(id: fixture.device.key.id, displayName: "Mac")])
        #expect(try fixture.persistence.journal.envelope(for: fixture.device.key) == fixture.device)
    }

    @Test func localHistoryJournalKeepsTheShippedV1Shape() throws {
        let fixture = try HistoryFixture()
        defer { fixture.stop() }
        let event = fixture.event
        let fixtureJSON = """
            {"formatVersion":1,"key":{"kind":"connectionHistory","id":"\(event.key.id)"},
             "version":{"modifiedAt":-978307100,"counter":1,"writerID":"\(event.version.writerID)"},
             "isDeleted":true}
            """
        let decoded = try HistorySyncCodec.decode(Data(fixtureJSON.utf8))
        #expect(decoded.key == event.key)
        #expect(decoded.isDeleted)
        #expect(try HistorySyncCodec.decode(HistorySyncCodec.encode(event)) == event)
        #expect(try HistorySyncCodec.decode(HistorySyncCodec.encode(fixture.device)) == fixture.device)
    }

    @Test func bootstrapRollsBackAndIgnoresRetiredVaultJournal() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let device = DeviceRecord(id: UUID(), displayName: "Local")
        let payload = VaultRecordPayload.device(device)
        let legacy = VaultEnvelope(key: payload.key, version: .baseline(writerID: UUID()), payload: payload)
        let row = try PersistentVaultSyncEntry(envelope: legacy, needsUpload: true)
        row.systemFieldsData = Data([1, 2, 3])
        context.insert(row)
        context.insert(PersistentDeviceRecord(device))
        try context.save()
        let persistence = HistorySyncPersistence(context: context)
        #expect(throws: (any Error).self) {
            _ = try persistence.applyRemote([], beforeSave: { throw CocoaError(.fileWriteUnknown) })
        }
        #expect(try context.fetchCount(FetchDescriptor<PersistentHistorySyncEntry>()) == 0)
        try persistence.prepare()
        try persistence.prepare()
        let created = try #require(context.fetch(FetchDescriptor<PersistentHistorySyncEntry>()).first)
        #expect(created.systemFieldsData == nil)
        #expect(
            created.envelope?.version
                == .baseline(writerID: try HistorySyncJournal(context: context, kind: .device).state().installationID))
        #expect(created.envelope?.version != legacy.version)
        #expect(created.needsUpload)
        #expect(try context.fetchCount(FetchDescriptor<PersistentHistorySyncEntry>()) == 1)
    }

}

@MainActor
private final class HistoryFixture {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    let defaults: UserDefaults
    let suite = "HistorySyncTests.\(UUID())"
    let destination = LifecycleNetwork()
    let persistence: HistorySyncPersistence
    let connectionSync: ConnectionHistorySyncCoordinator
    let deviceSync: DeviceSyncCoordinator
    var coordinator: HistoryRecordSyncCoordinator { connectionSync.core }
    let deviceNetwork = LifecycleNetwork()
    let event: HistoryEnvelope
    let device: HistoryEnvelope
    var scope: CloudSyncScope {
        CloudSyncScope(
            container: CloudSyncContainer.identifier, environment: "Test", account: "current-user",
            zone: HistoryRecordSyncCoordinator.zoneName, owner: CKCurrentUserDefaultName)
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
        _ = try persistence.applyRemote([event, device])
        try persistence.journal.markNeedsUpload([event.key, device.key])
        try container.mainContext.save()
        let destination = destination
        connectionSync = ConnectionHistorySyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in destination.transport })
        let deviceNetwork = deviceNetwork
        deviceSync = DeviceSyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: "Test",
            makeTransport: { _, _ in deviceNetwork.transport })
    }
    func start() async throws {
        connectionSync.start()
        deviceSync.start()
        await coordinator.lifecycle.operation?.value
        await deviceSync.core.lifecycle.operation?.value
        #expect(coordinator.lifecycle.isReadyToSend == connectionSync.isEnabled)
        #expect(deviceSync.core.lifecycle.isReadyToSend)
    }
    func stop() {
        coordinator.pause()
        deviceSync.pause()
        defaults.removePersistentDomain(forName: suite)
    }
    func record(_ key: HistoryRecordKey) -> CKRecord? {
        let owner = key.kind == .device ? deviceSync.core : coordinator
        return owner.recordToSave(
            CKRecord.ID(recordName: key.recordName, zoneID: owner.lifecycle.zoneID),
            engine: key.kind == .device ? deviceNetwork.nextEngine : destination.nextEngine)
    }
}

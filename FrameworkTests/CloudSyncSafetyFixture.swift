import CloudKit
import CryptoKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import Testing

@testable import TermindInfrastructure

enum SyncSafetyCategory: CaseIterable, Sendable {
    case vault, settings, metrics, history, device
}

@MainActor
private struct SyncSafetyAdapter {
    var lifecycle: CloudSyncLifecycle
    var recordNames: [String]
    var receive: ([CKRecord], [CKRecord.ID]) throws -> Void
    var conflict: (CKError) throws -> Void
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch?
    var record: (CKRecord.ID) -> CKRecord?
    var pendingNames: () throws -> Set<String>
    var markTombstone: () throws -> Void
    var failingMerge: (CloudSyncSafetyStore) throws -> Void
}

/// Real journals, coordinators, record coding and batch providers; only CloudKit transport is fake.
@MainActor
final class CloudSyncSafetyFixture {
    let container: ModelContainer
    let defaults: UserDefaults
    let defaultsName = "CloudSyncSafetyTests.\(UUID())"
    let network = LifecycleNetwork()
    let legacyNetwork = LifecycleNetwork()
    private let adapter: SyncSafetyAdapter
    var lifecycle: CloudSyncLifecycle { adapter.lifecycle }
    var recordIDs: [CKRecord.ID] {
        adapter.recordNames.map { CKRecord.ID(recordName: $0, zoneID: lifecycle.zoneID) }
    }
    var receive: ([CKRecord], [CKRecord.ID]) throws -> Void { adapter.receive }
    var conflict: (CKError) throws -> Void { adapter.conflict }
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch? { adapter.batch }
    var record: (CKRecord.ID) -> CKRecord? { adapter.record }
    var pendingNames: () throws -> Set<String> { adapter.pendingNames }
    var markTombstone: () throws -> Void { adapter.markTombstone }
    var failingMerge: (CloudSyncSafetyStore) throws -> Void { adapter.failingMerge }

    init(category: SyncSafetyCategory, url: URL? = nil, environment: String = "Test") throws {
        container = try TermindPersistence.makeContainer(inMemory: url == nil, url: url)
        defaults = UserDefaults(suiteName: defaultsName)!
        for key in [
            SettingsKey.iCloudSyncEnabled, SettingsKey.vaultSyncEnabled,
            SettingsKey.settingsSyncEnabled, SettingsKey.metricsSyncEnabled, SettingsKey.historySyncEnabled,
        ] { defaults.set(true, forKey: key) }
        let context = container.mainContext
        switch category {
        case .history, .device:
            adapter = try Self.history(
                context, defaults: defaults, network: network, legacy: legacyNetwork,
                environment: environment, devices: category == .device)
        case .vault:
            adapter = try Self.vault(context, defaults: defaults, network: network, environment: environment)
        case .settings:
            adapter = try Self.settings(context, defaults: defaults, network: network, environment: environment)
        case .metrics:
            adapter = try Self.metrics(context, defaults: defaults, network: network, environment: environment)
        }
        try context.save()
    }

    private static var version: VaultVersion {
        VaultVersion(
            modifiedAt: Date(timeIntervalSince1970: 100), counter: 1,
            writerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    }

    private static func vault(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String
    ) throws -> SyncSafetyAdapter {
        let journal = VaultSyncJournal(context: context)
        let payloads = ["First", "Second"].map { VaultRecordPayload.hostGroup(HostGroup(name: $0)) }
        let envelopes = payloads.map { VaultEnvelope(key: $0.key, version: version, payload: $0) }
        for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        let coordinator = VaultSyncCoordinator(
            context: context, defaults: defaults, environmentIdentifier: environment,
            makeTransport: { _, _ in network.transport })
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try HostPersistence(context: context).applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            })
    }

    private static func history(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, legacy: LifecycleNetwork,
        environment: String, devices: Bool
    ) throws -> SyncSafetyAdapter {
        let persistence = HistorySyncPersistence(context: context)
        try persistence.prepare()
        let envelopes = (0..<2).map { index in
            let payload: HistoryRecordPayload =
                devices
                ? .device(DeviceRecord(id: UUID(), displayName: "Device \(index)"))
                : .connectionHistory(ConnectionHistoryEntry(hostID: UUID(), kind: .ssh))
            return HistoryEnvelope(key: payload.key, version: version, payload: payload)
        }
        _ = try persistence.applyRemote(envelopes, importingLegacy: true)
        let journal = persistence.journal
        let coordinator = HistorySyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: environment,
            makeTransport: { _, _ in network.transport }, makeLegacyTransport: { _, _ in legacy.transport })
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                _ = try persistence.applyRemote([envelope], importingLegacy: true)
            },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try persistence.applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            })
    }

    private static func settings(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String
    ) throws -> SyncSafetyAdapter {
        let persistence = SettingsSyncPersistence(context: context, defaults: defaults)
        let journal = persistence.journal
        let payloads: [SettingsRecordPayload] = [.sftp(SFTPPreferences()), .ssh(SSHPreferences())]
        let envelopes = payloads.map { SettingsEnvelope(key: $0.key, version: version, payload: $0) }
        for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        let secrets = AISecretStore(context: context, keychain: InMemorySecretStore(), defaults: defaults)
        let coordinator = SettingsSyncCoordinator(
            persistence: persistence, secrets: secrets, defaults: defaults, environmentIdentifier: environment,
            makeTransport: { _, _ in network.transport })
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try persistence.applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            })
    }

    private static func metrics(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String
    ) throws -> SyncSafetyAdapter {
        let persistence = MetricsSyncPersistence(context: context, defaults: defaults)
        let journal = persistence.journal
        let envelopes = (0..<2).map { index in
            let payload = MetricsRecordPayload.selection(
                SyncedMetricsSelection(selection: MetricsSelection(id: UUID()), sortIndex: index))
            return MetricsEnvelope(key: payload.key, version: version, payload: payload)
        }
        for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        let coordinator = MetricsSyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: environment,
            makeTransport: { _, _ in network.transport })
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try persistence.applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            })
    }

    func start() async throws {
        lifecycle.start()
        await lifecycle.operation?.value
        #expect(lifecycle.isReadyToSend)
        _ = try #require(lifecycle.scope)
    }

    func stop() {
        lifecycle.pause()
        defaults.removePersistentDomain(forName: defaultsName)
    }

    func safety() throws -> CloudSyncSafetyStore {
        CloudSyncSafetyStore(context: container.mainContext, scope: try #require(lifecycle.scope))
    }

    func futureRecord() throws -> CKRecord {
        let record = try #require(record(recordIDs[0]))
        if HistorySyncCoordinator.recordTypes.contains(record.recordType) {
            record["formatVersion"] = NSNumber(value: 99)
            return record
        }
        let data = try #require(record["payload"] as? Data)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["formatVersion"] = 99
        let payload = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        Self.setPayload(payload, in: record)
        record["formatVersion"] = NSNumber(value: 99)
        return record
    }

    static func expectPreserved(_ record: CKRecord, in data: Data) throws {
        if HistorySyncCoordinator.recordTypes.contains(record.recordType) {
            let restored = try #require(try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data))
            #expect(restored.recordID == record.recordID)
            #expect(restored["formatVersion"] as? NSNumber == record["formatVersion"] as? NSNumber)
            #expect(Set(restored.allKeys()) == Set(record.allKeys()))
        } else {
            #expect(data == record["payload"] as? Data)
        }
    }

    static func setPayload(_ data: Data, in record: CKRecord) {
        record["payload"] = data as NSData
        record["payloadHash"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() as NSString
    }
}

// Seed exactly the mutations under test without bootstrapping unrelated application defaults.
extension VaultSyncJournal {
    fileprivate func upsert(_ envelope: VaultEnvelope, needsUpload: Bool) throws {
        try acceptRemote([envelope])
        if needsUpload { try markNeedsUpload([envelope.key]) }
    }
}

extension SettingsSyncJournal {
    fileprivate func upsert(_ envelope: SettingsEnvelope, needsUpload: Bool) throws {
        try acceptRemote([envelope])
        if needsUpload { try markNeedsUpload([envelope.key]) }
    }
}

extension MetricsSyncJournal {
    fileprivate func upsert(_ envelope: MetricsEnvelope, needsUpload: Bool) throws {
        try acceptRemote([envelope])
        if needsUpload { try markNeedsUpload([envelope.key]) }
    }
}

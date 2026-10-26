// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    var sent: (CloudSyncSentChanges) throws -> Void
    var cloudRecords: () throws -> [CloudSyncJournalRecord]
    var conflict: (CKError) throws -> Void
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch?
    var record: (CKRecord.ID) -> CKRecord?
    var newerRecord: (CKRecord.ID) throws -> CKRecord
    var olderRecord: (CKRecord.ID) throws -> CKRecord
    var sameVersionLosingRecord: (CKRecord.ID) throws -> CKRecord
    var pendingNames: () throws -> Set<String>
    var markTombstone: () throws -> Void
    var recreateFirst: () throws -> Bool
    var editFirstAgain: () throws -> Bool
    var projectionIsPopulated: () throws -> Bool
    var projectionIsCleared: () throws -> Bool
    var failingMerge: (CloudSyncSafetyStore) throws -> Void
    var remoteApplyCount: () -> Int
    var remoteApplyObservedCleared: () -> Bool
}

@MainActor
private final class RemoteApplyCounter {
    var value = 0
    var observedCleared = false
}

/// Real journals, coordinators, record coding and batch providers; only CloudKit transport is fake.
@MainActor
final class CloudSyncSafetyFixture {
    let container: ModelContainer
    let defaults: UserDefaults
    let defaultsName = "CloudSyncSafetyTests.\(UUID())"
    let network = LifecycleNetwork()
    private let adapter: SyncSafetyAdapter
    var lifecycle: CloudSyncLifecycle { adapter.lifecycle }
    var recordIDs: [CKRecord.ID] {
        adapter.recordNames.map { CKRecord.ID(recordName: $0, zoneID: lifecycle.zoneID) }
    }
    var receive: ([CKRecord], [CKRecord.ID]) throws -> Void { adapter.receive }
    var sent: (CloudSyncSentChanges) throws -> Void { adapter.sent }
    var cloudRecords: () throws -> [CloudSyncJournalRecord] { adapter.cloudRecords }
    var conflict: (CKError) throws -> Void { adapter.conflict }
    var batch: ([CKSyncEngine.PendingRecordZoneChange]) -> CKSyncEngine.RecordZoneChangeBatch? { adapter.batch }
    var record: (CKRecord.ID) -> CKRecord? { adapter.record }
    var newerRecord: (CKRecord.ID) throws -> CKRecord { adapter.newerRecord }
    var olderRecord: (CKRecord.ID) throws -> CKRecord { adapter.olderRecord }
    var sameVersionLosingRecord: (CKRecord.ID) throws -> CKRecord { adapter.sameVersionLosingRecord }
    var pendingNames: () throws -> Set<String> { adapter.pendingNames }
    var markTombstone: () throws -> Void { adapter.markTombstone }
    var recreateFirst: () throws -> Bool { adapter.recreateFirst }
    var editFirstAgain: () throws -> Bool { adapter.editFirstAgain }
    var projectionIsPopulated: () throws -> Bool { adapter.projectionIsPopulated }
    var projectionIsCleared: () throws -> Bool { adapter.projectionIsCleared }
    var failingMerge: (CloudSyncSafetyStore) throws -> Void { adapter.failingMerge }
    var remoteApplyCount: Int { adapter.remoteApplyCount() }
    var remoteApplyObservedCleared: Bool { adapter.remoteApplyObservedCleared() }

    init(
        category: SyncSafetyCategory, url: URL? = nil, environment: String = "Test", seed: Bool = true,
        assetCacheRoot: URL? = nil,
        removeAssetDirectory: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) throws {
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
                context, defaults: defaults, network: network,
                environment: environment, devices: category == .device, seed: seed)
        case .vault:
            adapter = try Self.vault(
                context, defaults: defaults, network: network, environment: environment, seed: seed,
                assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory)
        case .settings:
            adapter = try Self.settings(
                context, defaults: defaults, network: network, environment: environment, seed: seed,
                assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory)
        case .metrics:
            adapter = try Self.metrics(
                context, defaults: defaults, network: network, environment: environment, seed: seed,
                assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory)
        }
        try context.save()
    }

    private static var version: VaultVersion {
        VaultVersion(
            modifiedAt: Date(timeIntervalSince1970: 100), counter: 1,
            writerID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    }

    private static func vault(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String, seed: Bool,
        assetCacheRoot: URL?, removeAssetDirectory: @escaping (URL) throws -> Void
    ) throws -> SyncSafetyAdapter {
        let journal = VaultSyncJournal(context: context)
        let payloads = ["First", "Second"].enumerated().map { index, name in
            VaultRecordPayload.hostGroup(
                HostGroup(
                    id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", index + 1))!,
                    name: name))
        }
        let envelopes = payloads.map { VaultEnvelope(key: $0.key, version: version, payload: $0) }
        if seed {
            for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        }
        let coordinator = VaultSyncCoordinator(
            context: context, defaults: defaults, environmentIdentifier: environment,
            assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory,
            makeTransport: { _, _ in network.transport })
        let counter = RemoteApplyCounter()
        coordinator.didApplyRemote = { snapshot, _ in
            counter.value += 1
            counter.observedCleared = snapshot.groups.isEmpty
        }
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords,
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            newerRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter += 1
                return try VaultSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            olderRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter = 0
                return try VaultSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            sameVersionLosingRecord: { id in
                guard let local = envelopes.first(where: { $0.key.recordName == id.recordName }),
                    case .some(.hostGroup(var group)) = local.payload
                else { throw CocoaError(.fileReadNoSuchFile) }
                group.name = ""
                var remote = local
                remote.payload = .hostGroup(group)
                guard try VaultSyncCodec.encode(remote).lexicographicallyPrecedes(VaultSyncCodec.encode(local)) else {
                    throw CocoaError(.coderInvalidValue)
                }
                return try VaultSyncCoordinator.makeRecord(.init(envelope: remote), recordID: id)
            },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            recreateFirst: {
                guard case .hostGroup(var group) = payloads[0] else { return false }
                group.name = "Recreated group"
                _ = try HostPersistence(context: context).save(VaultSnapshot(groups: [group]))
                return true
            },
            editFirstAgain: {
                guard case .hostGroup(var group) = payloads[0] else { return false }
                group.name = "Edited group"
                _ = try HostPersistence(context: context).save(VaultSnapshot(groups: [group]))
                return true
            },
            projectionIsPopulated: {
                let ids = Set(try HostPersistence(context: context).load().groups.map(\.id))
                return ids
                    == Set(
                        payloads.compactMap { payload in
                            guard case .hostGroup(let group) = payload else { return nil }
                            return group.id
                        })
            },
            projectionIsCleared: { try HostPersistence(context: context).load().groups.isEmpty },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try HostPersistence(context: context).applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            },
            remoteApplyCount: { counter.value },
            remoteApplyObservedCleared: { counter.observedCleared })
    }

    private static func history(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork,
        environment: String, devices: Bool, seed: Bool
    ) throws -> SyncSafetyAdapter {
        let persistence = HistorySyncPersistence(context: context)
        try persistence.prepare()
        let envelopes = (0..<2).map { index in
            let id = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!
            let payload: HistoryRecordPayload =
                devices
                ? .device(DeviceRecord(id: id, displayName: "Device \(index)"))
                : .connectionHistory(
                    ConnectionHistoryEntry(
                        id: id,
                        hostID: UUID(uuidString: "21000000-0000-0000-0000-000000000001")!,
                        kind: .ssh))
            return HistoryEnvelope(key: payload.key, version: version, payload: payload)
        }
        if seed {
            _ = try persistence.applyRemote(envelopes)
            try persistence.journal.markNeedsUpload(Set(envelopes.map(\.key)))
        }
        let journal = persistence.journal
        let coordinator = HistoryRecordSyncCoordinator(
            persistence: persistence, kind: devices ? .device : .connectionHistory,
            defaults: defaults, environmentIdentifier: environment,
            makeTransport: { _, _ in network.transport })
        let counter = RemoteApplyCounter()
        coordinator.didApplyRemote = { _ in
            counter.value += 1
            let count: Int
            if devices {
                count = (try? context.fetchCount(FetchDescriptor<PersistentDeviceRecord>())) ?? -1
            } else {
                count = (try? context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>())) ?? -1
            }
            counter.observedCleared = count == 0
        }
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords,
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            newerRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter += 1
                return try HistoryRecordSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            olderRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter = 0
                return try HistoryRecordSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            sameVersionLosingRecord: { id in
                guard let local = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                var remote = local
                switch local.payload {
                case .some(.device(var device)):
                    device.displayName = ""
                    remote.payload = .device(device)
                case .some(.connectionHistory(var entry)):
                    entry.hostID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
                    remote.payload = .connectionHistory(entry)
                case nil:
                    throw CocoaError(.coderInvalidValue)
                }
                guard try HistorySyncCodec.encode(remote).lexicographicallyPrecedes(HistorySyncCodec.encode(local))
                else {
                    throw CocoaError(.coderInvalidValue)
                }
                return try HistoryRecordSyncCoordinator.makeRecord(.init(envelope: remote), recordID: id)
            },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                _ = try persistence.applyRemote([envelope])
                try journal.markNeedsUpload([envelope.key])
                try context.save()
            },
            recreateFirst: {
                guard devices, case .device(var device) = envelopes[0].payload else { return false }
                device.displayName = "Recreated device"
                try SwiftDataDeviceDirectoryRepository(context: context).upsert(device)
                return true
            },
            editFirstAgain: {
                guard devices, case .device(var device) = envelopes[0].payload else { return false }
                device.displayName = "Edited device"
                try SwiftDataDeviceDirectoryRepository(context: context).upsert(device)
                return true
            },
            projectionIsPopulated: {
                if devices {
                    return try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == envelopes.count
                }
                return try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == envelopes.count
            },
            projectionIsCleared: {
                if devices {
                    return try context.fetchCount(FetchDescriptor<PersistentDeviceRecord>()) == 0
                }
                return try context.fetchCount(FetchDescriptor<PersistentConnectionHistoryEntry>()) == 0
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
            },
            remoteApplyCount: { counter.value },
            remoteApplyObservedCleared: { counter.observedCleared })
    }

    private static func settings(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String, seed: Bool,
        assetCacheRoot: URL?, removeAssetDirectory: @escaping (URL) throws -> Void
    ) throws -> SyncSafetyAdapter {
        let persistence = SettingsSyncPersistence(context: context, defaults: defaults)
        let journal = persistence.journal
        let remoteWebSearch = AIWebSearchPreferences(isEnabled: false, prefersBuiltIn: true)
        let remoteTerminal = TerminalPreferences(darkTheme: "Remote Dark", shellIntegration: false)
        let payloads: [SettingsRecordPayload] = [.webSearch(remoteWebSearch), .terminal(remoteTerminal)]
        let envelopes = payloads.map { SettingsEnvelope(key: $0.key, version: version, payload: $0) }
        if seed {
            for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        }
        let secrets = AISecretStore(context: context, keychain: InMemorySecretStore(), defaults: defaults)
        let coordinator = SettingsSyncCoordinator(
            persistence: persistence, secrets: secrets, defaults: defaults, environmentIdentifier: environment,
            assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory,
            makeTransport: { _, _ in network.transport })
        let counter = RemoteApplyCounter()
        coordinator.didApplyRemote = { snapshot, _ in
            counter.value += 1
            counter.observedCleared =
                snapshot.webSearch == AIWebSearchPreferences()
                && snapshot.terminal == TerminalPreferences()
        }
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords,
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            newerRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter += 1
                return try SettingsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            olderRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter = 0
                return try SettingsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            sameVersionLosingRecord: { id in
                guard let local = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                var remote = local
                remote.payload = .webSearch(AIWebSearchPreferences(isEnabled: false, prefersBuiltIn: false))
                guard try SettingsSyncCodec.encode(remote).lexicographicallyPrecedes(SettingsSyncCodec.encode(local))
                else { throw CocoaError(.coderInvalidValue) }
                return try SettingsSyncCoordinator.makeRecord(.init(envelope: remote), recordID: id)
            },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            recreateFirst: {
                try persistence.saveWebSearch(
                    AIWebSearchPreferences(isEnabled: false, prefersBuiltIn: false))
                return true
            },
            editFirstAgain: {
                try persistence.saveWebSearch(
                    AIWebSearchPreferences(isEnabled: true, prefersBuiltIn: false))
                return true
            },
            projectionIsPopulated: {
                let snapshot = try persistence.load()
                return snapshot.webSearch == remoteWebSearch && snapshot.terminal == remoteTerminal
            },
            projectionIsCleared: {
                let snapshot = try persistence.load()
                return snapshot.webSearch == AIWebSearchPreferences()
                    && snapshot.terminal == TerminalPreferences()
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
            },
            remoteApplyCount: { counter.value },
            remoteApplyObservedCleared: { counter.observedCleared })
    }

    private static func metrics(
        _ context: ModelContext, defaults: UserDefaults, network: LifecycleNetwork, environment: String, seed: Bool,
        assetCacheRoot: URL?, removeAssetDirectory: @escaping (URL) throws -> Void
    ) throws -> SyncSafetyAdapter {
        let persistence = MetricsSyncPersistence(context: context, defaults: defaults)
        let journal = persistence.journal
        let payloads = (0..<2).map { index in
            MetricsRecordPayload.selection(
                SyncedMetricsSelection(
                    selection: MetricsSelection(
                        id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))!),
                    sortIndex: index))
        }
        let envelopes = payloads.map { MetricsEnvelope(key: $0.key, version: version, payload: $0) }
        if seed {
            for envelope in envelopes { try journal.upsert(envelope, needsUpload: true) }
        }
        let coordinator = MetricsSyncCoordinator(
            persistence: persistence, defaults: defaults, environmentIdentifier: environment,
            assetCacheRoot: assetCacheRoot, removeAssetDirectory: removeAssetDirectory,
            makeTransport: { _, _ in network.transport })
        let counter = RemoteApplyCounter()
        coordinator.didApplyRemote = { snapshot, _ in
            counter.value += 1
            counter.observedCleared = snapshot.selections.isEmpty
        }
        return SyncSafetyAdapter(
            lifecycle: coordinator.lifecycle, recordNames: envelopes.map(\.key.recordName),
            receive: { try coordinator.receiveRemoteRecords($0, deletions: $1) },
            sent: coordinator.handleSentChanges, cloudRecords: journal.cloudRecords,
            conflict: coordinator.handleFailedSave,
            batch: { coordinator.makeChangeBatch($0, engine: network.nextEngine) },
            record: { coordinator.recordToSave($0, engine: network.nextEngine) },
            newerRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter += 1
                return try MetricsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            olderRecord: { id in
                guard var envelope = envelopes.first(where: { $0.key.recordName == id.recordName }) else {
                    throw CocoaError(.fileReadNoSuchFile)
                }
                envelope.version.counter = 0
                return try MetricsSyncCoordinator.makeRecord(.init(envelope: envelope), recordID: id)
            },
            sameVersionLosingRecord: { id in
                guard let local = envelopes.first(where: { $0.key.recordName == id.recordName }),
                    case .some(.selection(var value)) = local.payload
                else { throw CocoaError(.fileReadNoSuchFile) }
                value.sortIndex = -1
                var remote = local
                remote.payload = .selection(value)
                guard try MetricsSyncCodec.encode(remote).lexicographicallyPrecedes(MetricsSyncCodec.encode(local))
                else { throw CocoaError(.coderInvalidValue) }
                return try MetricsSyncCoordinator.makeRecord(.init(envelope: remote), recordID: id)
            },
            pendingNames: { Set(try journal.pendingEnvelopes().map(\.key.recordName)) },
            markTombstone: {
                var envelope = envelopes[0]
                envelope.isDeleted = true
                envelope.payload = nil
                envelope.version.counter += 1
                try journal.upsert(envelope, needsUpload: true)
                try context.save()
            },
            recreateFirst: {
                guard case .selection(let selection) = payloads[0] else { return false }
                try persistence.save([selection.selection])
                return true
            },
            editFirstAgain: {
                guard case .selection(var selection) = payloads[0] else { return false }
                selection.selection.enabled = false
                try persistence.save([selection.selection])
                return true
            },
            projectionIsPopulated: {
                let ids = Set(try persistence.load().map(\.id))
                return ids
                    == Set(
                        payloads.compactMap { payload in
                            guard case .selection(let selection) = payload else { return nil }
                            return selection.selection.id
                        })
            },
            projectionIsCleared: { try persistence.load().isEmpty },
            failingMerge: { safety in
                var envelope = envelopes[0]
                envelope.version.counter += 1
                _ = try persistence.applyRemote(
                    [envelope],
                    beforeSave: {
                        try safety.clearQuarantine(recordName: envelope.key.recordName)
                        throw CocoaError(.fileWriteUnknown)
                    })
            },
            remoteApplyCount: { counter.value },
            remoteApplyObservedCleared: { counter.observedCleared })
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
        if HistoryRecordSyncCoordinator.recordTypes.contains(record.recordType) {
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
        if HistoryRecordSyncCoordinator.recordTypes.contains(record.recordType) {
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

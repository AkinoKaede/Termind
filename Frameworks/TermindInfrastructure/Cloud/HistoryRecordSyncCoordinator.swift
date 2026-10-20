// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import CloudKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence

/// Shared record handling; each owner has its own engine, state, subscription and safety scope.
/// The cloud zone and record identities remain stable across coordinator changes.
@MainActor
@Observable
final class HistoryRecordSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    nonisolated static let zoneName = "TermindConnectionHistoryV1"
    nonisolated static let recordTypes = Set(HistoryRecordKind.allCases.map(\.recordType))

    private let context: ModelContext
    private let persistence: HistorySyncPersistence
    private let kind: HistoryRecordKind
    private let journal: HistorySyncJournal
    private let makeTransport: (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    private let defaults: UserDefaults
    private let environmentIdentifier: String
    private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)

    @ObservationIgnored private(set) lazy var lifecycle = makeLifecycle()

    var status: VaultSyncStatus { lifecycle.status }
    var didApplyRemote: ((Set<HistoryRecordKey>) -> Void)?
    var isEnabled: Bool { lifecycle.isEnabled }
    private func includes(_ key: HistoryRecordKey) -> Bool { key.kind == kind }

    init(
        persistence: HistorySyncPersistence, kind: HistoryRecordKind,
        defaults: UserDefaults, environmentIdentifier: String,
        makeTransport: @escaping (CKRecordZone.ID, any CKSyncEngineDelegate) -> CloudSyncTransport
    ) {
        context = persistence.context
        self.persistence = persistence
        self.kind = kind
        journal = HistorySyncJournal(context: persistence.context, kind: kind)
        self.makeTransport = makeTransport
        self.defaults = defaults
        self.environmentIdentifier = environmentIdentifier
        super.init()
    }

    func configureLogging(_ logging: any ApplicationLogManaging) {
        lifecycle.logger = logging.makeLogger(label: "termind.cloud-sync")
    }

    func start() { lifecycle.start() }
    func setEnabled(_ enabled: Bool) { lifecycle.setEnabled(enabled) }
    func pause() { lifecycle.pause() }
    func retry() { lifecycle.retry() }
    func confirmAccountSwitchMerge() { lifecycle.confirmAccountSwitchMerge() }

    func noteLocalChanges(_ mutations: HistoryMutationSet) {
        lifecycle.noteLocalChanges(mutations.keys.filter(includes).map(\.recordName))
    }

    private func makeLifecycle() -> CloudSyncLifecycle {
        let journal = journal
        let context = context
        let kind = kind
        return CloudSyncLifecycle(
            store: CloudSyncLifecycleStore(
                state: journal.syncState, updateState: journal.updateSyncState,
                save: { try context.save() }, rollback: { context.rollback() },
                pendingChanges: {
                    try CloudSyncRecordStateStore(context: context, scope: $0).pendingChanges(journal.cloudRecords())
                },
                safety: .persistentHistory(context: context, kind: kind),
                resetForNewAccount: { try journal.resetForNewAccount() },
                resetForZone: { try journal.resetForZone() },
                resetForEnvironment: { try journal.resetForZone() },
                purge: { [weak self] scope in
                    guard let self else { throw CancellationError() }
                    let changed = try self.persistence.purgeCloudCache(kind: kind, scope: scope)
                    if !changed.isEmpty { self.didApplyRemote?(changed) }
                },
                replica: .persistent(
                    context: context, records: journal.cloudRecords,
                    clearSystemFields: journal.clearSystemFields,
                    handlesRecordName: {
                        HistoryRecordKey(recordName: $0).map { $0.kind == kind } == true
                    },
                    preservesNewerIncarnation: { recordName in
                        kind == .device && HistoryRecordKey(recordName: recordName)?.kind == .device
                    })),
            transport: makeTransport(zoneID, self),
            zoneID: zoneID, containerIdentifier: CloudSyncContainer.identifier, defaults: defaults,
            enabledKey: kind == .connectionHistory ? SettingsKey.historySyncEnabled : nil,
            defaultEnabled: SettingsKey.defaultHistorySyncEnabled,
            environmentKey: kind == .connectionHistory
                ? SettingsKey.historySyncEnvironment : SettingsKey.deviceSyncEnvironment,
            environmentIdentifier: environmentIdentifier,
            consumerIdentifier: kind == .device ? "device" : "",
            receiveSnapshot: { [weak self] in try self?.receiveRemoteRecords($0, deletions: $1) })
    }

    nonisolated func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        .init(scope: .zoneIDs([CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)]))
    }

    nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        await lifecycle.handle(
            CloudSyncEventInput(event), engine: syncEngine,
            receiveRemoteRecords: { try receiveRemoteRecords($0, deletions: $1) },
            handleSentChanges: handleSentChanges)
    }

    nonisolated func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await makeChangeBatch(context, engine: syncEngine)
    }

    private func makeChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, engine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        makeChangeBatch(
            engine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }, engine: engine)
    }

    func makeChangeBatch(
        _ pending: [CKSyncEngine.PendingRecordZoneChange], engine: any CloudSyncEngineSession
    ) -> CKSyncEngine.RecordZoneChangeBatch? {
        let excluded = Set(
            pending.compactMap { change -> String? in
                guard case .saveRecord(let id) = change, let key = HistoryRecordKey(recordName: id.recordName),
                    !includes(key)
                else { return nil }
                return id.recordName
            })
        engine.removePending(excluded, in: zoneID)
        return lifecycle.makeChangeBatch(pending, engine: engine) { recordToSave($0, engine: engine) }
    }

    func recordToSave(_ recordID: CKRecord.ID, engine: any CloudSyncEngineSession) -> CKRecord? {
        do {
            guard try lifecycle.canUpload(recordID, engine: engine), let scope = lifecycle.scope,
                let key = HistoryRecordKey(recordName: recordID.recordName), includes(key),
                let outgoing = try journal.outgoingEntry(for: key, scope: scope)
            else { return nil }
            return try Self.makeRecord(outgoing, recordID: recordID)
        } catch {
            lifecycle.failClosed(error)
            return nil
        }
    }

    func receiveRemoteRecords(
        _ records: [CKRecord], deletions: [CKRecord.ID] = [], isConflict: Bool = false
    ) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let reconciled = try lifecycle.reconcileRemoteChanges(records: records, deletions: deletions)
        let (records, deletions) = (reconciled.records, reconciled.deletions)
        lifecycle.noteRecordsObserved(records, excluding: deletions)
        let deletedKeys = Set(
            deletions.compactMap { id -> HistoryRecordKey? in
                guard id.zoneID == zoneID, let key = HistoryRecordKey(recordName: id.recordName), includes(key)
                else { return nil }
                return key
            })
        let deletedNames = Set(deletedKeys.map(\.recordName))
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let decoded: [(record: CKRecord, envelope: HistoryEnvelope)] = try decodeCloudSyncRecords(
            records.filter { !deletedNames.contains($0.recordID.recordName) },
            included: { record in
                guard record.recordID.zoneID == zoneID,
                    isConflict || record.recordType == kind.recordType
                else { return false }
                return HistoryRecordKey(recordName: record.recordID.recordName).map(includes) != false
            },
            decode: Self.envelope,
            quarantine: {
                try CloudSyncRecordCoding.quarantine($0, error: $1, in: safety, nativeFields: true)
            },
            logFailure: { lifecycle.logFailure($0, stage: "decode-quarantine") })
        let changed = try persistence.applyRemote(
            decoded.map { $0.1 }, deletions: deletedKeys,
            beforeSave: {
                for (record, envelope) in decoded {
                    try journal.noteRemoteRecord(record, envelope: envelope, cloud: cloud, safety: safety)
                }
                try journal.acknowledgeRemoteDeletions(deletedKeys, scope: scope)
            })
        try lifecycle.reconcilePendingChanges()
        if !changed.isEmpty { didApplyRemote?(changed) }
    }

    func handleSentChanges(_ changes: CloudSyncSentChanges) throws {
        guard let scope = lifecycle.scope else { throw CancellationError() }
        let safety = CloudSyncSafetyStore(context: context, scope: scope)
        let cloud = CloudSyncRecordStateStore(context: context, scope: scope)
        for record in changes.savedRecords
        where record.recordID.zoneID == zoneID
            && HistoryRecordKey(recordName: record.recordID.recordName).map(includes) == true
        {
            guard try !safety.isUploadBlocked(recordName: record.recordID.recordName) else { continue }
            try journal.acknowledgeSavedRecord(record, envelope: Self.envelope(from: record), cloud: cloud)
        }
        for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID {
            if failure.error.code == .unknownItem,
                try cloud.wasPresent(failure.record.recordID.recordName)
            {
                try receiveRemoteRecords([], deletions: [failure.record.recordID])
            } else {
                try handleFailedSave(failure.error)
            }
        }
        try lifecycle.handleDeletedRecords(changes) { mutation in
            try journal.acknowledgeDeletion(mutation, scope: scope)
        }
        try context.save()
        try lifecycle.reconcilePendingChanges()
    }

    func handleFailedSave(_ error: CKError) throws {
        try lifecycle.handleFailedSave(error) {
            try receiveRemoteRecords($0, isConflict: $1)
        }
    }

    nonisolated static func makeRecord(
        _ outgoing: HistoryOutgoingEntry, recordID: CKRecord.ID
    ) throws -> CKRecord {
        let envelope = outgoing.envelope
        let record = try CloudSyncRecordCoding.makeRecord(
            type: envelope.key.kind.recordType, id: recordID, systemFields: outgoing.systemFieldsData)
        if envelope.formatVersion == 2 {
            try HistoryCloudRecordV2.write(envelope, into: record)
        } else {
            try HistoryCloudRecordV1.write(envelope, into: record)
        }
        return record
    }

    nonisolated static func envelope(from record: CKRecord) throws -> HistoryEnvelope {
        if (record["formatVersion"] as? NSNumber)?.intValue == 2 {
            return try HistoryCloudRecordV2.read(record)
        }
        return try HistoryCloudRecordV1.read(record)
    }
}

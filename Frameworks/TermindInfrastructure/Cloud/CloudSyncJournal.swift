import CloudKit
import Foundation
import TermindDomain
import TermindPersistence

nonisolated protocol CloudSyncRecordKey: Hashable {
    var recordName: String { get }
}

nonisolated protocol CloudSyncEnvelope: Equatable {
    associatedtype Key: CloudSyncRecordKey
    var key: Key { get }
    var version: VaultVersion { get }
    var isDeleted: Bool { get }
}

/// The engine binding every category journal persists beside its records.
protocol CloudSyncJournalState: AnyObject {
    var engineStateData: Data? { get set }
    var boundUserRecordName: String? { get set }
    var pendingUserRecordName: String? { get set }
    var lastSuccessfulSync: Date? { get set }
}

/// The journal surface shared by the category-owned sync coordinators.
@MainActor
protocol CloudSyncJournal: AnyObject {
    associatedtype Envelope: CloudSyncEnvelope
    associatedtype State: CloudSyncJournalState
    typealias Key = Envelope.Key

    func state() throws -> State
    func cloudRecords() throws -> [CloudSyncJournalRecord]
    func envelope(for key: Key) throws -> Envelope?
    func markNeedsUpload(_ keys: Set<Key>) throws
    func markUploaded(_ key: Key, version: VaultVersion) throws
    func updateSystemFields(_ data: Data?, for key: Key) throws
    func acknowledgeDeletion(_ mutation: CloudSyncMutation, scope: CloudSyncScope) throws
}

extension CloudSyncJournal {
    func syncState() throws -> CloudSyncState {
        let state = try state()
        return CloudSyncState(
            engineStateData: state.engineStateData, boundUserRecordName: state.boundUserRecordName,
            pendingUserRecordName: state.pendingUserRecordName, lastSuccessfulSync: state.lastSuccessfulSync)
    }

    func updateSyncState(_ value: CloudSyncState) throws {
        let state = try state()
        state.engineStateData = value.engineStateData
        state.boundUserRecordName = value.boundUserRecordName
        state.pendingUserRecordName = value.pendingUserRecordName
        state.lastSuccessfulSync = value.lastSuccessfulSync
    }

    /// Records the cloud metadata of a remote value inside the merge transaction.
    func noteRemoteRecord(
        _ record: CKRecord, envelope: Envelope, cloud: CloudSyncRecordStateStore, safety: CloudSyncSafetyStore
    ) throws {
        let recordName = record.recordID.recordName
        try cloud.observed(recordName, version: envelope.version, current: cloudRecord(named: recordName))
        try updateSystemFields(CloudSyncRecordCoding.systemFields(of: record), for: envelope.key)
        if try self.envelope(for: envelope.key) == envelope {
            try markUploaded(envelope.key, version: envelope.version)
        }
        try safety.clearQuarantine(recordName: recordName)
    }

    /// A remote deletion completes a pending local tombstone for the same key.
    func acknowledgeRemoteDeletions(_ keys: Set<Key>, scope: CloudSyncScope) throws {
        for key in keys {
            guard let envelope = try envelope(for: key), envelope.isDeleted else { continue }
            try acknowledgeDeletion(
                .init(recordName: key.recordName, operation: .delete, version: envelope.version), scope: scope)
        }
    }

    func acknowledgeSavedRecord(_ record: CKRecord, envelope: Envelope, cloud: CloudSyncRecordStateStore) throws {
        let recordName = record.recordID.recordName
        let current = try self.envelope(for: envelope.key)
        try cloud.acknowledgeSave(
            .init(recordName: recordName, operation: .save, version: envelope.version),
            current: cloudRecord(named: recordName))
        if current?.isDeleted == true {
            // An in-flight save may finish after a local/remote deletion. Delete its server copy again.
            try markNeedsUpload([envelope.key])
        } else {
            try markUploaded(envelope.key, version: envelope.version)
            try updateSystemFields(CloudSyncRecordCoding.systemFields(of: record), for: envelope.key)
        }
    }

    private func cloudRecord(named recordName: String) throws -> CloudSyncJournalRecord? {
        try cloudRecords().first { $0.mutation.recordName == recordName }
    }
}

extension VaultRecordKey: CloudSyncRecordKey {}
extension SettingsRecordKey: CloudSyncRecordKey {}
extension MetricsRecordKey: CloudSyncRecordKey {}
extension HistoryRecordKey: CloudSyncRecordKey {}

extension VaultEnvelope: CloudSyncEnvelope {}
extension SettingsEnvelope: CloudSyncEnvelope {}
extension MetricsEnvelope: CloudSyncEnvelope {}
extension HistoryEnvelope: CloudSyncEnvelope {}

extension PersistentVaultSyncState: CloudSyncJournalState {}
extension PersistentAIConfigurationSyncState: CloudSyncJournalState {}
extension PersistentMetricsSyncState: CloudSyncJournalState {}
extension PersistentHistorySyncState: CloudSyncJournalState {}

extension VaultSyncJournal: CloudSyncJournal {}
extension SettingsSyncJournal: CloudSyncJournal {}
extension MetricsSyncJournal: CloudSyncJournal {}
extension HistorySyncJournal: CloudSyncJournal {}

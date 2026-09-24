import Foundation
import SwiftData
import TermindDomain

/// V37 sidecar: never discard knowledge of cloud existence when resetting an engine cursor.
@Model
public final class PersistentCloudSyncRecordState {
    @Attribute(.unique) public var storageKey = ""
    public var scopeKey = ""
    public var recordName = ""
    public var wasPresent = false
    public var confirmedDeletion: Data?
    public var legacyDeletion: Data?

    public init(scope: CloudSyncScope, recordName: String) {
        scopeKey = scope.storageKey
        self.recordName = recordName
        storageKey = scope.storageKey + "\(recordName.utf8.count):\(recordName)"
    }
}

@Model
public final class PersistentCloudSyncReplicaState {
    @Attribute(.unique) public var scopeKey = ""
    public var reconciled = false
    public init(scope: CloudSyncScope) { scopeKey = scope.storageKey }
}

@MainActor
public final class CloudSyncRecordStateStore {
    private let context: ModelContext
    public let scope: CloudSyncScope

    public init(context: ModelContext, scope: CloudSyncScope) {
        self.context = context
        self.scope = scope
    }

    public func prepare(_ records: [CloudSyncJournalRecord]) throws -> Bool {
        for record in records {
            if try entry(record.mutation.recordName) == nil {
                let row = try state(record.mutation.recordName)
                row.wasPresent = record.hasSystemFields
            }
        }
        return try !replica().reconciled
    }

    public func pendingChanges(_ records: [CloudSyncJournalRecord]) throws -> [CloudSyncMutation] {
        let blocked = try CloudSyncSafetyStore(context: context, scope: scope).blockedRecordNames()
        let states = Dictionary(uniqueKeysWithValues: try entries().map { ($0.recordName, $0) })
        var result = records.compactMap { record -> CloudSyncMutation? in
            let mutation = record.mutation
            guard !blocked.contains(mutation.recordName) else { return nil }
            if mutation.operation == .delete {
                let confirmed = states[mutation.recordName]?.confirmedDeletion.flatMap {
                    try? JSONDecoder().decode(VaultVersion.self, from: $0)
                }
                return record.needsUpload || confirmed != mutation.version ? mutation : nil
            }
            return record.needsUpload ? mutation : nil
        }
        let names = Set(result.map(\.recordName))
        for row in states.values where !blocked.contains(row.recordName) && !names.contains(row.recordName) {
            if let data = row.legacyDeletion {
                result.append(
                    .init(
                        recordName: row.recordName, operation: .delete,
                        version: try JSONDecoder().decode(VaultVersion.self, from: data)))
            }
        }
        return result.sorted { $0.recordName < $1.recordName }
    }

    public func observed(_ recordName: String) throws {
        let row = try state(recordName)
        row.wasPresent = true
        row.confirmedDeletion = nil
    }

    public func wasPresent(_ recordName: String) throws -> Bool {
        try entry(recordName)?.wasPresent == true
    }

    public func deleted(_ recordName: String, version: VaultVersion) throws {
        let row = try state(recordName)
        row.wasPresent = false
        row.confirmedDeletion = try JSONEncoder().encode(version)
        row.legacyDeletion = nil
    }

    public func queueLegacyDeletion(_ recordName: String, version: VaultVersion) throws {
        try observed(recordName)
        try state(recordName).legacyDeletion = JSONEncoder().encode(version)
    }

    public func acknowledgeLegacyDeletion(_ mutation: CloudSyncMutation) throws {
        guard let row = try entry(mutation.recordName),
            let data = row.legacyDeletion,
            try JSONDecoder().decode(VaultVersion.self, from: data) == mutation.version
        else { return }
        try deleted(mutation.recordName, version: mutation.version)
    }

    public func missingRecordNames(seen: Set<String>) throws -> [String] {
        try entries().filter { $0.wasPresent && !seen.contains($0.recordName) }.map(\.recordName)
    }

    public func completeReconciliation() throws { try replica().reconciled = true }

    /// An absent zone is a new replica, not a list of user record deletions.
    public func resetZone() throws {
        for row in try entries() { context.delete(row) }
        try replica().reconciled = false
    }

    private func replica() throws -> PersistentCloudSyncReplicaState {
        let key = scope.storageKey
        if let row = try context.fetch(
            FetchDescriptor<PersistentCloudSyncReplicaState>(
                predicate: #Predicate { $0.scopeKey == key })
        ).first {
            return row
        }
        let row = PersistentCloudSyncReplicaState(scope: scope)
        context.insert(row)
        return row
    }

    private func state(_ recordName: String) throws -> PersistentCloudSyncRecordState {
        if let row = try entry(recordName) { return row }
        let row = PersistentCloudSyncRecordState(scope: scope, recordName: recordName)
        context.insert(row)
        return row
    }

    private func entry(_ name: String) throws -> PersistentCloudSyncRecordState? {
        let key = scope.storageKey
        return try context.fetch(
            FetchDescriptor<PersistentCloudSyncRecordState>(
                predicate: #Predicate { $0.scopeKey == key && $0.recordName == name })
        ).first
    }

    private func entries() throws -> [PersistentCloudSyncRecordState] {
        let key = scope.storageKey
        return try context.fetch(
            FetchDescriptor<PersistentCloudSyncRecordState>(
                predicate: #Predicate { $0.scopeKey == key }))
    }
}

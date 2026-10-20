// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
    // Retained in the shipped V37 model shape; old cleanup intent is no longer read.
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

/// V38 sidecar recording the exact delete incarnation handed to CloudKit.
/// It closes the crash window between a successful server delete and its local acknowledgement.
@Model
public final class PersistentCloudSyncDeletionHandoff {
    @Attribute(.unique) public var storageKey = ""
    public var scopeKey = ""
    public var recordName = ""
    public var versionData = Data()

    public init(scope: CloudSyncScope, recordName: String, versionData: Data) {
        scopeKey = scope.storageKey
        self.recordName = recordName
        self.versionData = versionData
        storageKey = scope.storageKey + "\(recordName.utf8.count):\(recordName)"
    }
}

/// V38 durable work item for category-owned filesystem cache cleanup.
@Model
public final class PersistentCloudSyncAssetCleanup {
    @Attribute(.unique) public var storageKey = ""
    public var scopeKey = ""
    public var cacheKey = ""

    public init(scope: CloudSyncScope, cacheKey: String) {
        scopeKey = scope.storageKey
        self.cacheKey = cacheKey
        storageKey = scope.storageKey + "\(cacheKey.utf8.count):\(cacheKey)"
    }
}

@MainActor
public final class CloudSyncAssetCleanupStore {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func markPending(scope: CloudSyncScope, cacheKey: String) throws {
        guard try pending(scope: scope, cacheKey: cacheKey) == nil else { return }
        context.insert(PersistentCloudSyncAssetCleanup(scope: scope, cacheKey: cacheKey))
    }

    public func isPending(scope: CloudSyncScope, cacheKey: String) throws -> Bool {
        try pending(scope: scope, cacheKey: cacheKey) != nil
    }

    public func isPending(cacheKey: String) throws -> Bool {
        try !pending(cacheKey: cacheKey).isEmpty
    }

    public func complete(cacheKey: String) throws {
        for row in try pending(cacheKey: cacheKey) { context.delete(row) }
    }

    private func pending(scope: CloudSyncScope, cacheKey: String) throws -> PersistentCloudSyncAssetCleanup? {
        let scopeKey = scope.storageKey
        var descriptor = FetchDescriptor<PersistentCloudSyncAssetCleanup>(
            predicate: #Predicate { $0.scopeKey == scopeKey && $0.cacheKey == cacheKey })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func pending(cacheKey: String) throws -> [PersistentCloudSyncAssetCleanup] {
        try context.fetch(
            FetchDescriptor<PersistentCloudSyncAssetCleanup>(
                predicate: #Predicate { $0.cacheKey == cacheKey }))
    }
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
        let result = records.compactMap { record -> CloudSyncMutation? in
            let mutation = record.mutation
            guard !blocked.contains(mutation.recordName) else { return nil }
            if mutation.operation == .delete {
                let state = states[mutation.recordName]
                let confirmed = state?.confirmedDeletion.flatMap {
                    try? JSONDecoder().decode(VaultVersion.self, from: $0)
                }
                return record.needsUpload || state?.wasPresent == true || confirmed != mutation.version
                    ? mutation : nil
            }
            return record.needsUpload ? mutation : nil
        }
        return result.sorted { $0.recordName < $1.recordName }
    }

    public func observed(
        _ recordName: String, version: VaultVersion? = nil,
        current: CloudSyncJournalRecord? = nil
    ) throws {
        let row = try state(recordName)
        let causal = try causalDeletionVersion(recordName, row: row)
        if let version, let causal, let current,
            current.mutation.operation == .save, current.needsUpload,
            causal < current.mutation.version, version <= causal
        {
            return
        }
        row.wasPresent = true
        if let causal, let version {
            if causal < version { row.confirmedDeletion = nil }
        } else {
            row.confirmedDeletion = nil
        }
    }

    /// A save acknowledgement supersedes an older handed-off delete when it proves
    /// that incarnation, or an even newer local edit, exists after the delete.
    public func acknowledgeSave(_ saved: CloudSyncMutation, current: CloudSyncJournalRecord?) throws {
        try observed(saved.recordName, version: saved.version, current: current)
        guard saved.operation == .save, let current, current.mutation.operation == .save,
            saved.version <= current.mutation.version, let handoff = try handoff(saved.recordName),
            try JSONDecoder().decode(VaultVersion.self, from: handoff.versionData) < saved.version
        else { return }
        context.delete(handoff)
    }

    public func wasPresent(_ recordName: String) throws -> Bool {
        try entry(recordName)?.wasPresent == true
    }

    public func deleted(_ recordName: String, version: VaultVersion) throws {
        let row = try state(recordName)
        row.wasPresent = false
        row.confirmedDeletion = try JSONEncoder().encode(version)
        if let handoff = try handoff(recordName) { context.delete(handoff) }
    }

    public func recordDeletionHandoff(_ mutation: CloudSyncMutation) throws {
        guard mutation.operation == .delete else { return }
        let data = try JSONEncoder().encode(mutation.version)
        if let row = try handoff(mutation.recordName) {
            row.versionData = data
        } else {
            context.insert(
                PersistentCloudSyncDeletionHandoff(
                    scope: scope, recordName: mutation.recordName, versionData: data))
        }
    }

    public func cancelDeletionHandoff(_ mutation: CloudSyncMutation) throws {
        guard let row = try handoff(mutation.recordName),
            try JSONDecoder().decode(VaultVersion.self, from: row.versionData) == mutation.version
        else { return }
        context.delete(row)
    }

    /// Returns physical deletions from a full inventory and live records that are a
    /// newer explicit incarnation than a delete handed off before a crash.
    public func missingRecordNames(
        seen: Set<String>, records: [CloudSyncJournalRecord],
        includes: (String) -> Bool = { _ in true },
        preservesNewerIncarnation: (String) -> Bool = { _ in true }
    ) throws -> (deleted: [String], recreated: [String]) {
        let missing = try entries().filter {
            $0.wasPresent && includes($0.recordName) && !seen.contains($0.recordName)
        }.map(\.recordName)
        return try reconcileDeletions(
            missing, records: records, preservesNewerIncarnation: preservesNewerIncarnation)
    }

    /// Reconciles incremental deletion increments against the same durable
    /// delete-incarnation fence used by a full inventory.
    public func reconcileDeletions(
        _ recordNames: [String], records: [CloudSyncJournalRecord],
        preservesNewerIncarnation: (String) -> Bool = { _ in true }
    ) throws -> (deleted: [String], recreated: [String]) {
        let current = Dictionary(uniqueKeysWithValues: records.map { ($0.mutation.recordName, $0) })
        var deleted: [String] = []
        var recreated: [String] = []
        for recordName in Set(recordNames).sorted() {
            let row = try entry(recordName)
            let causal = try causalDeletionVersion(recordName, row: row)
            if preservesNewerIncarnation(recordName), let causal, let record = current[recordName],
                record.mutation.operation == .save, record.needsUpload, causal < record.mutation.version
            {
                // The deletion confirms only the old handed-off incarnation is gone.
                // Forget its cloud metadata; the explicit newer live value remains pending.
                let state: PersistentCloudSyncRecordState
                if let row {
                    state = row
                } else {
                    state = try self.state(recordName)
                }
                state.wasPresent = false
                state.confirmedDeletion = try JSONEncoder().encode(causal)
                recreated.append(recordName)
            } else {
                deleted.append(recordName)
            }
        }
        return (deleted, recreated)
    }

    public func completeReconciliation() throws { try replica().reconciled = true }

    /// An absent zone is a new replica, not a list of user record deletions.
    public func resetZone() throws {
        for row in try entries() { context.delete(row) }
        for row in try handoffs() { context.delete(row) }
        try replica().reconciled = false
    }

    public func purgeScope() throws {
        for row in try entries() { context.delete(row) }
        for row in try handoffs() { context.delete(row) }
        let key = scope.storageKey
        for row in try context.fetch(
            FetchDescriptor<PersistentCloudSyncReplicaState>(predicate: #Predicate { $0.scopeKey == key }))
        {
            context.delete(row)
        }
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

    private func handoff(_ name: String) throws -> PersistentCloudSyncDeletionHandoff? {
        let key = scope.storageKey
        return try context.fetch(
            FetchDescriptor<PersistentCloudSyncDeletionHandoff>(
                predicate: #Predicate { $0.scopeKey == key && $0.recordName == name })
        ).first
    }

    private func handoffs() throws -> [PersistentCloudSyncDeletionHandoff] {
        let key = scope.storageKey
        return try context.fetch(
            FetchDescriptor<PersistentCloudSyncDeletionHandoff>(predicate: #Predicate { $0.scopeKey == key }))
    }

    private func causalDeletionVersion(
        _ recordName: String, row: PersistentCloudSyncRecordState?
    ) throws -> VaultVersion? {
        let confirmed = row?.confirmedDeletion.flatMap {
            try? JSONDecoder().decode(VaultVersion.self, from: $0)
        }
        let handedOff = try handoff(recordName).flatMap {
            try JSONDecoder().decode(VaultVersion.self, from: $0.versionData)
        }
        return [confirmed, handedOff].compactMap { $0 }.max()
    }
}

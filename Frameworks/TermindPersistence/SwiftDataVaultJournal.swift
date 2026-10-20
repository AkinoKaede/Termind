// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindApplication
import TermindDomain

public nonisolated enum VaultSyncPersistenceError: LocalizedError {
    case invalidEnvelope(String)
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope(let recordName):
            String(localized: "The iCloud Vault record \(recordName) is invalid.")
        case .unsupportedFormat(let version):
            String(localized: "This Vault record requires sync format \(version).")
        }
    }
}

public nonisolated struct VaultRemoteMerge: Sendable {
    public var accepted: [VaultEnvelope] = []
    public var needsUpload: Set<VaultRecordKey> = []
}

public nonisolated struct VaultOutgoingEntry: Sendable {
    public var envelope: VaultEnvelope
    public var systemFieldsData: Data?
    public init(envelope: VaultEnvelope, systemFieldsData: Data? = nil) {
        self.envelope = envelope
        self.systemFieldsData = systemFieldsData
    }
}

extension VaultSnapshot {
    public nonisolated var recordPayloads: [VaultRecordKey: VaultRecordPayload] {
        var result: [VaultRecordKey: VaultRecordPayload] = [:]
        for value in hosts { result[VaultRecordKey(kind: .host, id: value.id)] = .host(value) }
        for var value in groups {
            value.isExpanded = true
            result[VaultRecordKey(kind: .hostGroup, id: value.id)] = .hostGroup(value)
        }
        for value in identities { result[VaultRecordKey(kind: .identity, id: value.id)] = .identity(value) }
        for value in keys {
            result[VaultRecordKey(kind: .sshKey, id: value.id)] = .sshKey(value)
        }
        for value in knownHosts {
            result[VaultRecordKey(kind: .knownHost, id: value.id)] = .knownHost(value)
        }
        for value in snippets {
            result[VaultRecordKey(kind: .snippet, id: value.id)] = .snippet(value)
        }
        for var value in snippetPackages {
            value.isExpanded = true
            result[VaultRecordKey(kind: .snippetPackage, id: value.id)] = .snippetPackage(value)
        }
        for value in portForwardings {
            result[VaultRecordKey(kind: .portForwarding, id: value.id)] = .portForwarding(value)
        }
        for value in workspaceTemplates {
            result[VaultRecordKey(kind: .workspaceTemplate, id: value.id)] = .workspaceTemplate(value)
        }
        return result
    }

    public nonisolated mutating func apply(_ envelope: VaultEnvelope) throws {
        try SyncRecordFormats.vault.validate(kind: envelope.key.kind.rawValue, version: envelope.formatVersion)
        guard envelope.isValid else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }

        if envelope.isDeleted {
            remove(envelope.key)
            return
        }
        guard let payload = envelope.payload else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        switch payload {
        case .host(var value):
            value.createdAt = value.createdAt ?? hosts.first(where: { $0.id == value.id })?.createdAt
            upsert(value, in: &hosts)
        case .hostGroup(let value): upsert(value, in: &groups)
        case .identity(let value): upsert(value, in: &identities)
        case .sshKey(let value): upsert(value, in: &keys)
        case .knownHost(let value): upsert(value, in: &knownHosts)
        case .snippet(let value): upsert(value, in: &snippets)
        case .snippetPackage(let value): upsert(value, in: &snippetPackages)
        case .portForwarding(let value): upsert(value, in: &portForwardings)
        case .workspaceTemplate(let value): upsert(value, in: &workspaceTemplates)
        case .connectionHistory:
            // Connection history is persisted independently by HostPersistence
            // so HostLibrary snapshots cannot accidentally replace it.
            break
        case .device: break
        }
    }

    private nonisolated mutating func remove(_ key: VaultRecordKey) {
        switch key.kind {
        case .host: hosts.removeAll { $0.id == key.id }
        case .hostGroup: groups.removeAll { $0.id == key.id }
        case .identity: identities.removeAll { $0.id == key.id }
        case .sshKey: keys.removeAll { $0.id == key.id }
        case .knownHost: knownHosts.removeAll { $0.id == key.id }
        case .snippet: snippets.removeAll { $0.id == key.id }
        case .snippetPackage: snippetPackages.removeAll { $0.id == key.id }
        case .portForwarding: portForwardings.removeAll { $0.id == key.id }
        case .workspaceTemplate: workspaceTemplates.removeAll { $0.id == key.id }
        case .connectionHistory: break
        case .device: break
        }
    }

    private nonisolated func upsert<Value: Identifiable>(
        _ value: Value, in values: inout [Value]
    ) where Value.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) {
            values[index] = value
        } else {
            values.append(value)
        }
    }
}

extension VaultRecordPayload {
    fileprivate var withoutDeviceLocalMetadata: Self {
        switch self {
        case .hostGroup(var value):
            value.isExpanded = true
            return .hostGroup(value)
        case .snippetPackage(var value):
            value.isExpanded = true
            return .snippetPackage(value)
        default:
            return self
        }
    }
}

extension VaultEnvelope {
    var withoutDeviceLocalMetadata: Self {
        var copy = self
        copy.payload = payload?.withoutDeviceLocalMetadata
        return copy
    }
}

@MainActor
public final class VaultSyncJournal {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func state() throws -> PersistentVaultSyncState {
        var descriptor = FetchDescriptor<PersistentVaultSyncState>()
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first { return existing }
        let state = PersistentVaultSyncState()
        context.insert(state)
        return state
    }

    @discardableResult
    public func bootstrapIfNeeded(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        let state = try state()
        guard !state.bootstrapCompleted else { return .empty }
        let existing = try entriesByName()
        var changed = Set<VaultRecordKey>()
        for payload in snapshot.recordPayloads.values {
            let key = payload.key
            guard existing[key.recordName] == nil else { continue }
            let envelope = VaultEnvelope(
                key: key, version: .baseline(writerID: state.installationID), payload: payload
            )
            context.insert(try PersistentVaultSyncEntry(envelope: envelope, needsUpload: true))
            changed.insert(key)
        }
        state.bootstrapCompleted = true
        return VaultMutationSet(keys: changed)
    }

    public func recordLocalChanges(
        from oldSnapshot: VaultSnapshot, to newSnapshot: VaultSnapshot,
        touching touchedKeys: Set<VaultRecordKey> = [],
        now: Date = .now
    ) throws -> VaultMutationSet {
        let state = try state()
        let old = oldSnapshot.recordPayloads
        let new = newSnapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<VaultRecordKey>()

        for (key, payload) in new where old[key] != payload || touchedKeys.contains(key) {
            let row = entries[key.recordName]
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }

        for key in old.keys where new[key] == nil {
            let row = entries[key.recordName]
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }
        return VaultMutationSet(keys: changed)
    }

    public func pendingEnvelopes() throws -> [VaultEnvelope] {
        try context.fetch(
            FetchDescriptor<PersistentVaultSyncEntry>(
                predicate: #Predicate { $0.needsUpload }
            )
        ).compactMap(\.envelope).filter { $0.key.kind.isConfiguration }.map(\.withoutDeviceLocalMetadata)
    }

    public func outgoingEntry(for key: VaultRecordKey, scope: CloudSyncScope? = nil) throws -> VaultOutgoingEntry? {
        // Restored pre-V35 CKSyncEngine queues can still contain legacy history IDs.
        guard key.kind.isConfiguration else { return nil }
        if let scope,
            try CloudSyncSafetyStore(context: context, scope: scope).isUploadBlocked(recordName: key.recordName)
        {
            return nil
        }
        guard let row = try entry(recordName: key.recordName), row.needsUpload, let envelope = row.envelope,
            !envelope.isDeleted
        else {
            return nil
        }
        return VaultOutgoingEntry(
            envelope: envelope.withoutDeviceLocalMetadata,
            systemFieldsData: row.systemFieldsData
        )
    }

    public func envelope(for key: VaultRecordKey) throws -> VaultEnvelope? {
        try entry(recordName: key.recordName)?.envelope?.withoutDeviceLocalMetadata
    }

    public func modificationDates() throws -> [VaultRecordKey: Date] {
        var result: [VaultRecordKey: Date] = [:]
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>())
        where HistoryRecordKey(recordName: row.recordName) == nil {
            guard let envelope = row.envelope, !envelope.isDeleted else { continue }
            result[envelope.key] = envelope.version.modifiedAt
        }
        return result
    }

    public func mergeDecision(for remote: [VaultEnvelope]) throws -> VaultRemoteMerge {
        var result = VaultRemoteMerge()
        let entries = try entriesByName()
        for rawEnvelope in remote where rawEnvelope.key.kind.isConfiguration {
            var envelope = rawEnvelope.withoutDeviceLocalMetadata
            try SyncRecordFormats.vault.validate(kind: envelope.key.kind.rawValue, version: envelope.formatVersion)
            guard envelope.isValid else {
                throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            guard
                let local = entries[envelope.key.recordName]?.envelope?.withoutDeviceLocalMetadata
            else {
                result.accepted.append(envelope)
                continue
            }
            if local.isDeleted && !envelope.isDeleted && entries[envelope.key.recordName]?.needsUpload == true {
                result.needsUpload.insert(local.key)
                continue
            }
            if local.version < envelope.version {
                if case .host(var incoming) = envelope.payload, incoming.createdAt == nil,
                    case .host(let existing) = local.payload, let createdAt = existing.createdAt
                {
                    incoming.createdAt = createdAt
                    envelope.payload = .host(incoming)
                    envelope.formatVersion = 8
                    result.needsUpload.insert(envelope.key)
                }
                result.accepted.append(envelope)
            } else if envelope.version < local.version {
                result.needsUpload.insert(local.key)
            } else if local != envelope {
                let localData = try VaultSyncCodec.encode(local)
                let remoteData = try VaultSyncCodec.encode(envelope)
                if localData.lexicographicallyPrecedes(remoteData) {
                    result.accepted.append(envelope)
                } else {
                    result.needsUpload.insert(local.key)
                }
            }
        }
        return result
    }

    public func acceptRemote(_ envelopes: [VaultEnvelope]) throws {
        var entries = try entriesByName()
        for envelope in envelopes where envelope.key.kind.isConfiguration {
            try store(envelope.withoutDeviceLocalMetadata, needsUpload: false, in: &entries)
        }
    }

    public func markNeedsUpload(_ keys: Set<VaultRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys { entries[key.recordName]?.needsUpload = true }
    }

    public func markUploaded(_ key: VaultRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), let envelope = row.envelope,
            envelope.version == version
        else {
            return
        }
        let normalized = envelope.withoutDeviceLocalMetadata
        guard row.needsUpload || envelope != normalized else { return }
        try row.apply(normalized, needsUpload: false)
    }

    public func updateSystemFields(_ data: Data?, for key: VaultRecordKey) throws {
        guard let row = try entry(recordName: key.recordName), row.systemFieldsData != data else { return }
        row.systemFieldsData = data
    }

    public func clearSystemFields(recordName: String) throws {
        try entry(recordName: recordName)?.systemFieldsData = nil
    }

    public func recordCurrentSnapshot(_ snapshot: VaultSnapshot, now: Date = .now) throws
        -> VaultMutationSet
    {
        let state = try state()
        let current = snapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<VaultRecordKey>()

        for (key, payload) in current {
            let row = entries[key.recordName]
            guard
                row?.envelope?.withoutDeviceLocalMetadata.payload != payload
                    || row?.envelope?.isDeleted != false
            else {
                continue
            }
            let envelope = VaultEnvelope(
                key: key,
                version: .next(after: row?.envelope?.version, writerID: state.installationID, now: now),
                payload: payload
            )
            try store(envelope, needsUpload: true, in: &entries)
            changed.insert(key)
        }

        for row in entries.values {
            guard let envelope = row.envelope, !envelope.isDeleted,
                current[envelope.key] == nil
            else { continue }
            let tombstone = VaultEnvelope(
                key: envelope.key,
                version: .next(after: envelope.version, writerID: state.installationID, now: now),
                isDeleted: true
            )
            try row.apply(tombstone, needsUpload: true)
            changed.insert(envelope.key)
        }
        return VaultMutationSet(keys: changed)
    }

    public func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>())
        where HistoryRecordKey(recordName: row.recordName) == nil {
            guard let envelope = row.envelope else { continue }
            if envelope.isDeleted {
                context.delete(row)
            } else {
                row.needsUpload = true
                row.systemFieldsData = nil
            }
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    public func markAllEntriesNeedsUploadAfterZoneReset() throws {
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>())
        where HistoryRecordKey(recordName: row.recordName) == nil {
            row.needsUpload = true
            row.systemFieldsData = nil
        }
        let state = try state()
        state.engineStateData = nil
        state.lastSuccessfulSync = nil
    }

    /// CloudKit record system fields include environment-specific change tags.
    /// Keep every local envelope, but discard those tags and the serialized
    /// engine state before moving between Development and Production.
    public func markAllEntriesNeedsUploadAfterEnvironmentChange() throws {
        try markAllEntriesNeedsUploadAfterZoneReset()
    }

    private func entry(recordName: String) throws -> PersistentVaultSyncEntry? {
        var descriptor = FetchDescriptor<PersistentVaultSyncEntry>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func store(
        _ envelope: VaultEnvelope, needsUpload: Bool,
        in entries: inout [String: PersistentVaultSyncEntry]
    ) throws {
        if let row = entries[envelope.key.recordName] {
            if row.envelope?.isDeleted == true && !envelope.isDeleted { row.systemFieldsData = nil }
            try row.apply(envelope, needsUpload: needsUpload)
        } else {
            let row = try PersistentVaultSyncEntry(
                envelope: envelope, needsUpload: needsUpload
            )
            context.insert(row)
            entries[envelope.key.recordName] = row
        }
    }

    private func entriesByName() throws -> [String: PersistentVaultSyncEntry] {
        Dictionary(
            try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).filter {
                HistoryRecordKey(recordName: $0.recordName) == nil
            }.map {
                ($0.recordName, $0)
            },
            uniquingKeysWith: { first, duplicate in
                if let firstVersion = first.envelope?.version,
                    let duplicateVersion = duplicate.envelope?.version,
                    firstVersion < duplicateVersion
                {
                    return duplicate
                }
                return first
            }
        )
    }
}

extension VaultSyncJournal {
    public func cloudRecords() throws -> [CloudSyncJournalRecord] {
        try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).compactMap { row in
            guard let envelope = row.envelope else { return nil }
            let key = envelope.key
            guard key.kind.isConfiguration else { return nil }
            return CloudSyncJournalRecord(
                recordName: key.recordName, version: envelope.version, isDeleted: envelope.isDeleted,
                needsUpload: row.needsUpload, hasSystemFields: row.systemFieldsData != nil)
        }
    }

    public func deletionEnvelopes(_ keys: Set<VaultRecordKey>) throws -> [VaultEnvelope] {
        try keys.compactMap { key in
            guard key.kind.isConfiguration else { return nil }
            let row = try entry(recordName: key.recordName)
            // Preserve undecodable local data until a compatible client can reconcile it.
            if let row, row.envelope == nil { return nil }
            let old = row?.envelope
            if let old, old.isDeleted { return old }
            return VaultEnvelope(
                key: key, version: .next(after: old?.version, writerID: try state().installationID), isDeleted: true)
        }
    }

    public func acknowledgeDeletion(_ mutation: CloudSyncMutation, scope: CloudSyncScope) throws {
        guard let key = VaultRecordKey(recordName: mutation.recordName), key.kind.isConfiguration,
            let row = try entry(recordName: mutation.recordName), let envelope = row.envelope
        else { return }
        if !envelope.isDeleted && row.needsUpload && mutation.version < envelope.version {
            // A later explicit recreation is still pending; acknowledge only the old server incarnation.
            try updateSystemFields(nil, for: key)
            try CloudSyncRecordStateStore(context: context, scope: scope).deleted(
                key.recordName, version: mutation.version)
            return
        }
        guard envelope.isDeleted, envelope.version == mutation.version else { return }
        try markUploaded(key, version: mutation.version)
        try updateSystemFields(nil, for: key)
        try CloudSyncRecordStateStore(context: context, scope: scope).deleted(key.recordName, version: mutation.version)
    }
}

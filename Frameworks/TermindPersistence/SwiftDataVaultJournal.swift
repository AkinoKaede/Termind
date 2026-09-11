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
        for value in groups {
            result[VaultRecordKey(kind: .hostGroup, id: value.id)] = .hostGroup(value)
        }
        for value in identities {
            result[VaultRecordKey(kind: .identity, id: value.id)] = .identity(value)
        }
        for value in keys {
            result[VaultRecordKey(kind: .sshKey, id: value.id)] = .sshKey(value)
        }
        for value in knownHosts {
            result[VaultRecordKey(kind: .knownHost, id: value.id)] = .knownHost(value)
        }
        for value in snippets {
            result[VaultRecordKey(kind: .snippet, id: value.id)] = .snippet(value)
        }
        for value in snippetPackages {
            result[VaultRecordKey(kind: .snippetPackage, id: value.id)] = .snippetPackage(value)
        }
        for value in portForwardings {
            result[VaultRecordKey(kind: .portForwarding, id: value.id)] = .portForwarding(value)
        }
        return result
    }

    public nonisolated mutating func apply(_ envelope: VaultEnvelope) throws {
        guard envelope.formatVersion <= VaultEnvelope.currentFormatVersion else {
            throw VaultSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
        }
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
        case .host(let value): upsert(value, in: &hosts)
        case .hostGroup(let value): upsert(value, in: &groups)
        case .identity(let value): upsert(value, in: &identities)
        case .sshKey(let value): upsert(value, in: &keys)
        case .knownHost(let value): upsert(value, in: &knownHosts)
        case .snippet(let value): upsert(value, in: &snippets)
        case .snippetPackage(let value): upsert(value, in: &snippetPackages)
        case .portForwarding(let value): upsert(value, in: &portForwardings)
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
        now: Date = .now
    ) throws -> VaultMutationSet {
        let state = try state()
        let old = oldSnapshot.recordPayloads
        let new = newSnapshot.recordPayloads
        var entries = try entriesByName()
        var changed = Set<VaultRecordKey>()

        for (key, payload) in new where old[key] != payload {
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
        ).compactMap(\.envelope)
    }

    public func outgoingEntry(for key: VaultRecordKey) throws -> VaultOutgoingEntry? {
        guard let row = try entry(recordName: key.recordName), let envelope = row.envelope else {
            return nil
        }
        return VaultOutgoingEntry(envelope: envelope, systemFieldsData: row.systemFieldsData)
    }

    public func envelope(for key: VaultRecordKey) throws -> VaultEnvelope? {
        try entry(recordName: key.recordName)?.envelope
    }

    public func mergeDecision(for remote: [VaultEnvelope]) throws -> VaultRemoteMerge {
        var result = VaultRemoteMerge()
        let entries = try entriesByName()
        for envelope in remote {
            guard envelope.formatVersion <= VaultEnvelope.currentFormatVersion else {
                throw VaultSyncPersistenceError.unsupportedFormat(envelope.formatVersion)
            }
            guard envelope.isValid else {
                throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
            }
            guard let local = entries[envelope.key.recordName]?.envelope else {
                result.accepted.append(envelope)
                continue
            }
            if local.version < envelope.version {
                result.accepted.append(envelope)
            } else if envelope.version < local.version {
                result.needsUpload.insert(local.key)
            } else if local != envelope {
                let localData = VaultSyncCodec.encode(local)
                let remoteData = VaultSyncCodec.encode(envelope)
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
        for envelope in envelopes {
            try store(envelope, needsUpload: false, in: &entries)
        }
    }

    public func markNeedsUpload(_ keys: Set<VaultRecordKey>) throws {
        let entries = try entriesByName()
        for key in keys { entries[key.recordName]?.needsUpload = true }
    }

    public func markUploaded(_ key: VaultRecordKey, version: VaultVersion) throws {
        guard let row = try entry(recordName: key.recordName), row.envelope?.version == version else {
            return
        }
        row.needsUpload = false
    }

    public func updateSystemFields(_ data: Data?, for key: VaultRecordKey) throws {
        try entry(recordName: key.recordName)?.systemFieldsData = data
    }

    public func quarantine(recordName: String, payloadData: Data, reason: String) throws {
        var descriptor = FetchDescriptor<PersistentVaultSyncQuarantine>(
            predicate: #Predicate { $0.recordName == recordName }
        )
        descriptor.fetchLimit = 1
        if let row = try context.fetch(descriptor).first {
            row.payloadData = payloadData
            row.reason = reason
            row.receivedAt = .now
        } else {
            context.insert(
                PersistentVaultSyncQuarantine(
                    recordName: recordName, payloadData: payloadData, reason: reason
                ))
        }
    }

    public func clearQuarantine(recordName: String) throws {
        try context.delete(
            model: PersistentVaultSyncQuarantine.self,
            where: #Predicate { $0.recordName == recordName }
        )
    }

    public func firstQuarantineReason() throws -> String? {
        var descriptor = FetchDescriptor<PersistentVaultSyncQuarantine>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.reason
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
            guard row?.envelope?.payload != payload || row?.envelope?.isDeleted != false else {
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
            row.apply(tombstone, needsUpload: true)
            changed.insert(envelope.key)
        }
        return VaultMutationSet(keys: changed)
    }

    public func markAllLiveRecordsNeedsUploadForNewAccount() throws {
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) {
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
        for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) {
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
            row.apply(envelope, needsUpload: needsUpload)
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
            try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()).map {
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

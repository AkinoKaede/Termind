import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@MainActor
public final class HostPersistence {
    public static let schema = TermindPersistence.schema

    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func load() throws -> VaultSnapshot {
        let snapshot = try fetchSnapshot()
        let journal = VaultSyncJournal(context: context)
        _ = try journal.bootstrapIfNeeded(snapshot)
        _ = try journal.recordCurrentConnectionHistory(fetchConnectionHistory())
        _ = try journal.recordCurrentDevices(fetchDevices())
        if context.hasChanges { try context.save() }
        return snapshot
    }

    private func fetchSnapshot() throws -> VaultSnapshot {
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
        let groups = try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value)
        let identities = try context.fetch(FetchDescriptor<PersistentIdentity>()).map(\.value)
        let keys = try context.fetch(FetchDescriptor<PersistentSSHKey>()).map(\.value)
        let knownHosts = try context.fetch(FetchDescriptor<PersistentKnownHost>()).map(\.value)
        let snippets = try context.fetch(FetchDescriptor<PersistentSnippet>()).map(\.value)
        let snippetPackages = try context.fetch(FetchDescriptor<PersistentSnippetPackage>()).map(\.value)
        let portForwardings = try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()).map(\.value)
        let workspaceTemplates = try context.fetch(FetchDescriptor<PersistentWorkspaceTemplate>()).map {
            try $0.value()
        }
        return VaultSnapshot(
            hosts: hosts, groups: groups, identities: identities, keys: keys,
            knownHosts: knownHosts, snippets: snippets,
            snippetPackages: snippetPackages, portForwardings: portForwardings,
            workspaceTemplates: workspaceTemplates
        )
    }

    public func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        try save(snapshot, touching: [])
    }

    public func save(
        _ snapshot: VaultSnapshot, touching keys: Set<VaultRecordKey>
    ) throws -> VaultMutationSet {
        do {
            let oldSnapshot = try fetchSnapshot()
            let journal = VaultSyncJournal(context: context)
            _ = try journal.bootstrapIfNeeded(oldSnapshot)
            let mutations = try journal.recordLocalChanges(
                from: oldSnapshot, to: snapshot, touching: keys)
            try persist(snapshot)
            try context.save()
            return mutations
        } catch {
            context.rollback()
            throw error
        }
    }

    public func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        try applyRemote(envelopes, beforeSave: {})
    }

    public func applyRemote(
        _ envelopes: [VaultEnvelope], beforeSave: () throws -> Void
    ) throws -> VaultRemoteApplyResult {
        do {
            let journal = VaultSyncJournal(context: context)
            let decision = try journal.mergeDecision(for: envelopes)
            var snapshot = try fetchSnapshot()
            for envelope in decision.accepted {
                if envelope.key.kind == .connectionHistory {
                    try applyConnectionHistory(envelope)
                } else if envelope.key.kind == .device {
                    try applyDevice(envelope)
                } else {
                    try snapshot.apply(envelope)
                }
            }
            try pruneConnectionHistory()
            try persist(snapshot)
            try journal.acceptRemote(decision.accepted)
            let retentionMutations = try journal.recordCurrentConnectionHistory(
                fetchConnectionHistory())
            let deviceMutations = try journal.recordCurrentDevices(fetchDevices())
            let needsUpload = decision.needsUpload
                .union(retentionMutations.keys)
                .union(deviceMutations.keys)
            try journal.markNeedsUpload(needsUpload)
            try beforeSave()
            try context.save()
            return VaultRemoteApplyResult(
                snapshot: snapshot,
                acceptedKeys: Set(decision.accepted.map(\.key)),
                needsUpload: needsUpload
            )
        } catch {
            context.rollback()
            throw error
        }
    }

    public func recordExternalMutation() throws -> VaultMutationSet {
        let snapshot = try fetchSnapshot()
        let journal = VaultSyncJournal(context: context)
        _ = try journal.bootstrapIfNeeded(snapshot)
        let vault = try journal.recordCurrentSnapshot(snapshot)
        let history = try journal.recordCurrentConnectionHistory(fetchConnectionHistory())
        let devices = try journal.recordCurrentDevices(fetchDevices())
        return VaultMutationSet(keys: vault.keys.union(history.keys).union(devices.keys))
    }

    public func modificationDates() throws -> [VaultRecordKey: Date] {
        try VaultSyncJournal(context: context).modificationDates()
    }

    private func persist(_ snapshot: VaultSnapshot) throws {
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentHost>()), with: snapshot.hosts,
            rowID: \.id, valueID: \.id,
            make: PersistentHost.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentHostGroup>()), with: snapshot.groups,
            rowID: \.id, valueID: \.id,
            make: PersistentHostGroup.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentIdentity>()), with: snapshot.identities,
            rowID: \.id, valueID: \.id,
            make: PersistentIdentity.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSSHKey>()), with: snapshot.keys,
            rowID: \.id, valueID: \.id,
            make: PersistentSSHKey.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentKnownHost>()), with: snapshot.knownHosts,
            rowID: \.id, valueID: \.id,
            make: PersistentKnownHost.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSnippet>()), with: snapshot.snippets,
            rowID: \.id, valueID: \.id,
            make: PersistentSnippet.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentSnippetPackage>()),
            with: snapshot.snippetPackages, rowID: \.id, valueID: \.id,
            make: PersistentSnippetPackage.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentPortForwardingRule>()),
            with: snapshot.portForwardings, rowID: \.id, valueID: \.id,
            make: PersistentPortForwardingRule.init, apply: { $0.apply($1) }
        )
        try reconcile(
            try context.fetch(FetchDescriptor<PersistentWorkspaceTemplate>()),
            with: snapshot.workspaceTemplates, rowID: \.id, valueID: \.id,
            make: PersistentWorkspaceTemplate.init, apply: { try $0.apply($1) }
        )
    }

    private func fetchConnectionHistory() throws -> [ConnectionHistoryEntry] {
        try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .map(\.value)
            .sorted(by: ConnectionHistoryEntry.isNewer)
    }

    private func applyConnectionHistory(_ envelope: VaultEnvelope) throws {
        let id = envelope.key.id
        var descriptor = FetchDescriptor<PersistentConnectionHistoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if envelope.isDeleted {
            if let existing { context.delete(existing) }
            return
        }
        guard case .connectionHistory(let value) = envelope.payload else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        if let existing {
            existing.apply(value)
        } else {
            context.insert(PersistentConnectionHistoryEntry(value))
        }
    }

    private func fetchDevices() throws -> [DeviceRecord] {
        try context.fetch(FetchDescriptor<PersistentDeviceRecord>()).map(\.value)
    }

    private func applyDevice(_ envelope: VaultEnvelope) throws {
        let id = envelope.key.id
        var descriptor = FetchDescriptor<PersistentDeviceRecord>(
            predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let existing = try context.fetch(descriptor).first
        if envelope.isDeleted {
            if let existing { context.delete(existing) }
            return
        }
        guard case .device(let value) = envelope.payload else {
            throw VaultSyncPersistenceError.invalidEnvelope(envelope.key.recordName)
        }
        if let existing {
            existing.displayName = value.displayName
        } else {
            context.insert(PersistentDeviceRecord(value))
        }
    }

    private func pruneConnectionHistory() throws {
        let rows = try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>())
            .sorted { ConnectionHistoryEntry.isNewer($0.value, $1.value) }
        for row in rows.dropFirst(ConnectionHistoryModel.limit) { context.delete(row) }
    }

    private func reconcile<Model: PersistentModel, Value>(
        _ rows: [Model], with values: [Value],
        rowID: (Model) -> UUID, valueID: (Value) -> UUID,
        make: (Value) throws -> Model, apply: (Model, Value) throws -> Void
    ) throws {
        var byID: [UUID: Model] = [:]
        for row in rows {
            let id = rowID(row)
            if byID[id] == nil { byID[id] = row } else { context.delete(row) }
        }
        let wanted = Set(values.map(valueID))
        for row in byID.values where !wanted.contains(rowID(row)) { context.delete(row) }
        for value in values {
            if let row = byID[valueID(value)] {
                try apply(row, value)
            } else {
                context.insert(try make(value))
            }
        }
    }
}

extension HostPersistence: VaultPersisting {}

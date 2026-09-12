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
        _ = try VaultSyncJournal(context: context).bootstrapIfNeeded(snapshot)
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
        return VaultSnapshot(
            hosts: hosts, groups: groups, identities: identities, keys: keys,
            knownHosts: knownHosts, snippets: snippets,
            snippetPackages: snippetPackages, portForwardings: portForwardings
        )
    }

    public func save(_ snapshot: VaultSnapshot) throws -> VaultMutationSet {
        do {
            let oldSnapshot = try fetchSnapshot()
            let journal = VaultSyncJournal(context: context)
            _ = try journal.bootstrapIfNeeded(oldSnapshot)
            let mutations = try journal.recordLocalChanges(from: oldSnapshot, to: snapshot)
            try persist(snapshot)
            try context.save()
            return mutations
        } catch {
            context.rollback()
            throw error
        }
    }

    public func applyRemote(_ envelopes: [VaultEnvelope]) throws -> VaultRemoteApplyResult {
        do {
            let journal = VaultSyncJournal(context: context)
            let decision = try journal.mergeDecision(for: envelopes)
            var snapshot = try fetchSnapshot()
            for envelope in decision.accepted { try snapshot.apply(envelope) }
            try persist(snapshot)
            try journal.acceptRemote(decision.accepted)
            try journal.markNeedsUpload(decision.needsUpload)
            try context.save()
            return VaultRemoteApplyResult(
                snapshot: snapshot,
                acceptedKeys: Set(decision.accepted.map(\.key)),
                needsUpload: decision.needsUpload
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
        return try journal.recordCurrentSnapshot(snapshot)
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
    }

    private func reconcile<Model: PersistentModel, Value>(
        _ rows: [Model], with values: [Value],
        rowID: (Model) -> UUID, valueID: (Value) -> UUID,
        make: (Value) -> Model, apply: (Model, Value) -> Void
    ) throws {
        var byID: [UUID: Model] = [:]
        for row in rows {
            let id = rowID(row)
            if byID[id] == nil { byID[id] = row } else { context.delete(row) }
        }
        let wanted = Set(values.map(valueID))
        for row in byID.values where !wanted.contains(rowID(row)) { context.delete(row) }
        for value in values {
            if let row = byID[valueID(value)] { apply(row, value) } else { context.insert(make(value)) }
        }
    }
}

extension HostPersistence: VaultPersisting {}

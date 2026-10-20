// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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
        if context.hasChanges { try context.save() }
        return snapshot
    }

    private func fetchSnapshot() throws -> VaultSnapshot {
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
        let groups = try Self.groups(in: context)
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
        _ envelopes: [VaultEnvelope], deletions: Set<VaultRecordKey> = [], beforeSave: () throws -> Void
    ) throws -> VaultRemoteApplyResult {
        do {
            let journal = VaultSyncJournal(context: context)
            let deleted = try journal.deletionEnvelopes(deletions)
            var snapshot = try fetchSnapshot()
            let knownDates = Dictionary(
                uniqueKeysWithValues: snapshot.hosts.compactMap { host in host.createdAt.map { (host.id, $0) } })
            var restoredDates = Set<VaultRecordKey>()
            let incoming = envelopes.filter { !deletions.contains($0.key) }.map { original in
                var envelope = original
                if case .host(var host) = envelope.payload, host.createdAt == nil,
                    let date = knownDates[host.id]
                {
                    host.createdAt = date
                    envelope.payload = .host(host)
                    envelope.formatVersion = 8
                    restoredDates.insert(envelope.key)
                }
                return envelope
            }
            let decision = try journal.mergeDecision(for: incoming + deleted)
            for envelope in decision.accepted { try snapshot.apply(envelope) }
            try persist(snapshot)
            try journal.acceptRemote(decision.accepted)
            let needsUpload = decision.needsUpload.union(
                restoredDates.intersection(decision.accepted.map(\.key)))
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
        return vault
    }

    public func modificationDates() throws -> [VaultRecordKey: Date] {
        try VaultSyncJournal(context: context).modificationDates()
    }

    /// Applies an account-owner CloudKit purge as one local persistence transaction.
    /// Installation identity and account binding remain stable, while no old snapshot
    /// or journal row remains available for bootstrap/re-upload.
    public func purgeCloudCache(
        scope: CloudSyncScope, assetCleanupKey: String? = nil
    ) throws -> (VaultSnapshot, Set<VaultRecordKey>) {
        var removed = Set<VaultRecordKey>()
        do {
            try context.commit {
                let journal = VaultSyncJournal(context: context)
                removed = Set(
                    try journal.cloudRecords().compactMap { VaultRecordKey(recordName: $0.mutation.recordName) })
                try persist(VaultSnapshot())
                for row in try context.fetch(FetchDescriptor<PersistentVaultSyncEntry>()) { context.delete(row) }
                let state = try journal.state()
                state.bootstrapCompleted = true
                state.engineStateData = nil
                state.pendingUserRecordName = nil
                state.lastSuccessfulSync = nil
                try CloudSyncSafetyStore(context: context, scope: scope).purgeScope()
                try CloudSyncRecordStateStore(context: context, scope: scope).purgeScope()
                if let assetCleanupKey {
                    try CloudSyncAssetCleanupStore(context: context).markPending(
                        scope: scope, cacheKey: assetCleanupKey)
                }
            }
            return (VaultSnapshot(), removed)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func persist(_ snapshot: VaultSnapshot) throws {
        guard snapshot.hosts.allSatisfy({ !$0.isTailscaleManaged }) else {
            throw TailscaleConfigurationError.managedHost
        }
        try persistTailscaleGroups(snapshot.groups)
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

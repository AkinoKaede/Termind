import Foundation
import SwiftData

@MainActor
final class SwiftDataHostRepository: HostRepository {
    private let context: ModelContext
    private var continuations: [UUID: AsyncStream<RepositoryChange<HostLibrarySnapshot>>.Continuation] = [:]
    var didRecordVaultChanges: ((VaultMutationSet) -> Void)?

    init(context: ModelContext) {
        self.context = context
    }

    func snapshot() throws -> RepositoryChange<HostLibrarySnapshot> {
        let hidden = Set(
            try context.fetch(
                FetchDescriptor<PersistentPendingDeletion>(
                    predicate: #Predicate { $0.entityType == "host" }
                )
            ).map(\.entityID)
        )
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>())
            .map(\.value)
            .filter { !hidden.contains($0.id) }
        let groups = try context.fetch(FetchDescriptor<PersistentHostGroup>()).map(\.value)
        return RepositoryChange(
            revision: try currentRevision(),
            value: HostLibrarySnapshot(hosts: hosts, groups: groups),
            reason: .initial
        )
    }

    func changes() -> AsyncStream<RepositoryChange<HostLibrarySnapshot>> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            if let initial = try? snapshot() { continuation.yield(initial) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.continuations[id] = nil }
            }
        }
    }

    func refresh() throws {
        try publishMutation(reason: .refresh)
    }

    func upsertHost(_ host: Host) throws {
        let hostID = host.id
        var descriptor = FetchDescriptor<PersistentHost>(predicate: #Predicate { $0.id == hostID })
        descriptor.fetchLimit = 1
        if let existing = try context.fetch(descriptor).first {
            existing.apply(host)
        } else {
            context.insert(PersistentHost(host))
        }
        try commitMutation()
    }

    func deletionImpact(for hostID: Host.ID) throws -> HostDeletionImpact {
        let hosts = try context.fetch(FetchDescriptor<PersistentHost>())
        let snippets = try context.fetch(FetchDescriptor<PersistentSnippet>())
        let rules = try forwardingRules(for: hostID)
        return HostDeletionImpact(
            jumpHostReferences: hosts.filter { $0.jumpHostID == hostID }.count,
            snippetReferences: snippets.filter { $0.targetHostIDs.contains(hostID) }.count,
            forwardingRules: rules.count
        )
    }

    /// The deletion marker, all durable side effects, and the revision become
    /// visible in one database commit. A crash can therefore see either the
    /// live host or a complete deletion saga, never half of each.
    func requestHostDeletion(_ hostID: Host.ID) throws {
        guard try persistentHost(hostID) != nil else { return }
        if try pendingDeletion(hostID) != nil { return }

        let ruleIDs = try forwardingRules(for: hostID).map(\.id)
        let payload = try JSONEncoder().encode(
            HostDeletionPayload(hostID: hostID, forwardingRuleIDs: ruleIDs)
        )
        let eventID = UUID()
        let now = Date()
        context.insert(
            PersistentPendingDeletion(
                entityType: "host", entityID: hostID, createdAt: now
            )
        )
        for handlerID in HostDeletionOutbox.handlerIDs {
            context.insert(
                PersistentOutboxJob(
                    OutboxJob(
                        eventID: eventID, handlerID: handlerID,
                        eventType: HostDeletionOutbox.eventType, payload: payload,
                        createdAt: now, nextAttemptAt: now
                    )
                )
            )
        }
        try commitMutation()
    }

    func clearReferencesForDeletedHost(_ hostID: Host.ID) throws {
        for host in try context.fetch(FetchDescriptor<PersistentHost>())
        where host.jumpHostID == hostID {
            host.jumpHostID = nil
        }
        for snippet in try context.fetch(FetchDescriptor<PersistentSnippet>())
        where snippet.targetHostIDs.contains(hostID) {
            snippet.targetHostIDs.removeAll { $0 == hostID }
        }
        for rule in try forwardingRules(for: hostID) { context.delete(rule) }
        try context.delete(
            model: PersistentCommandHistoryEntry.self,
            where: #Predicate { $0.hostID == hostID }
        )
        try context.delete(
            model: PersistentSFTPHistoryEntry.self,
            where: #Predicate { $0.hostID == hostID }
        )
        try context.delete(
            model: PersistentConnectionHistoryEntry.self,
            where: #Predicate { $0.hostID == hostID }
        )
        try commitMutation()
    }

    func finalizeHostDeletion(_ hostID: Host.ID) throws {
        if let host = try persistentHost(hostID) { context.delete(host) }
        if let marker = try pendingDeletion(hostID) { context.delete(marker) }
        try commitMutation()
    }

    private func publishMutation(reason: RepositoryChangeReason) throws {
        let revision = try advanceRevision()
        let current = try snapshot()
        let change = RepositoryChange(
            revision: revision, value: current.value, reason: reason
        )
        for continuation in continuations.values { continuation.yield(change) }
    }

    private func commitMutation() throws {
        do {
            let revision = try advanceRevisionWithoutSaving()
            let vaultMutations = try HostPersistence(context: context).recordExternalMutation()
            try context.save()
            if !vaultMutations.isEmpty { didRecordVaultChanges?(vaultMutations) }
            try publishCommittedMutation(revision: revision)
        } catch {
            context.rollback()
            throw error
        }
    }

    private func publishCommittedMutation(revision: Int64) throws {
        let current = try snapshot()
        let change = RepositoryChange(
            revision: revision, value: current.value, reason: .mutation
        )
        for continuation in continuations.values { continuation.yield(change) }
    }

    private func persistentHost(_ id: Host.ID) throws -> PersistentHost? {
        var descriptor = FetchDescriptor<PersistentHost>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func pendingDeletion(_ hostID: Host.ID) throws -> PersistentPendingDeletion? {
        var descriptor = FetchDescriptor<PersistentPendingDeletion>(
            predicate: #Predicate { $0.entityType == "host" && $0.entityID == hostID }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func forwardingRules(
        for hostID: Host.ID
    ) throws -> [PersistentPortForwardingRule] {
        try context.fetch(
            FetchDescriptor<PersistentPortForwardingRule>(
                predicate: #Predicate { $0.hostID == hostID }
            )
        )
    }

    private func currentRevision() throws -> Int64 {
        var descriptor = FetchDescriptor<PersistentDatabaseMetadata>(
            predicate: #Predicate { $0.key == "repository" }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.revision ?? 0
    }

    private func advanceRevision() throws -> Int64 {
        let revision = try advanceRevisionWithoutSaving()
        try context.save()
        return revision
    }

    private func advanceRevisionWithoutSaving() throws -> Int64 {
        var descriptor = FetchDescriptor<PersistentDatabaseMetadata>(
            predicate: #Predicate { $0.key == "repository" }
        )
        descriptor.fetchLimit = 1
        let metadata: PersistentDatabaseMetadata
        if let existing = try context.fetch(descriptor).first {
            metadata = existing
        } else {
            metadata = PersistentDatabaseMetadata()
            context.insert(metadata)
        }
        metadata.revision &+= 1
        return metadata.revision
    }
}

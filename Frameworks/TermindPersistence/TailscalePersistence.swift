import Foundation
import SwiftData
import TermindApplication
import TermindDomain

/// Versioned group configuration is separate from the frozen historical Group model.
@Model
public final class PersistentTailscaleGroup {
    @Attribute(.unique) public var id: UUID
    public var configurationData: Data
    public init(id: UUID, configuration: TailscaleGroupConfiguration) throws {
        self.id = id
        configurationData = try JSONEncoder().encode(configuration)
    }
    public func configuration() throws -> TailscaleGroupConfiguration {
        try JSONDecoder().decode(TailscaleGroupConfiguration.self, from: configurationData)
    }
}

public typealias PersistentTailscaleLocalState = TermindSchemaV48TailscaleModels.PersistentTailscaleLocalState

/// Device-local retry intent; never part of a Vault envelope.
@Model
public final class PersistentTailscaleProfileCleanup {
    @Attribute(.unique) public var profileID: UUID
    public init(profileID: UUID) { self.profileID = profileID }
}

extension HostPersistence {
    static func groups(in context: ModelContext) throws -> [HostGroup] {
        let configurations = try Dictionary(
            uniqueKeysWithValues:
                context.fetch(FetchDescriptor<PersistentTailscaleGroup>()).map { ($0.id, try $0.configuration()) })
        return try context.fetch(FetchDescriptor<PersistentHostGroup>()).map {
            var group = $0.value
            group.tailscale = configurations[group.id]
            return group
        }
    }

    func persistTailscaleGroups(_ groups: [HostGroup]) throws {
        let wanted = Dictionary(
            uniqueKeysWithValues: groups.compactMap { group in
                group.tailscale.map { (group.id, $0) }
            })
        let rows = try context.fetch(FetchDescriptor<PersistentTailscaleGroup>())
        let existing = Set(rows.map(\.id))
        for row in rows {
            if let configuration = wanted[row.id] {
                row.configurationData = try JSONEncoder().encode(configuration)
            } else {
                context.delete(row)
            }
        }
        for (id, configuration) in wanted where !existing.contains(id) {
            context.insert(try PersistentTailscaleGroup(id: id, configuration: configuration))
        }
    }
}

@MainActor
public final class SwiftDataTailscaleLocalStore: TailscaleLocalStoring {
    private let context: ModelContext
    public init(context: ModelContext) { self.context = context }
    public func load() throws -> [TailscaleLocalState] {
        try context.fetch(FetchDescriptor<PersistentTailscaleLocalState>()).map {
            TailscaleLocalState(
                groupID: $0.groupID, profileID: $0.profileID,
                peers: $0.peersData.isEmpty ? [] : try JSONDecoder().decode([TailscalePeer].self, from: $0.peersData),
                hostname: $0.hostname)
        }
    }
    public func save(_ state: TailscaleLocalState) throws {
        let data = try JSONEncoder().encode(state.peers)
        try context.commit {
            if let row = try context.fetch(FetchDescriptor<PersistentTailscaleLocalState>()).first(where: {
                $0.groupID == state.groupID
            }) {
                if row.profileID != state.profileID { try enqueueCleanup(row.profileID) }
                row.profileID = state.profileID
                row.peersData = data
                row.hostname = state.hostname
            } else {
                context.insert(
                    PersistentTailscaleLocalState(
                        groupID: state.groupID, profileID: state.profileID, peersData: data, hostname: state.hostname))
            }
            try deleteCleanup(state.profileID)
        }
    }
    public func remove(groupID: UUID) throws {
        try context.commit {
            for row in try context.fetch(FetchDescriptor<PersistentTailscaleLocalState>()) where row.groupID == groupID
            {
                try enqueueCleanup(row.profileID)
                context.delete(row)
            }
        }
    }

    public func scheduleCleanup(profileID: UUID) throws {
        try context.commit { try enqueueCleanup(profileID) }
    }

    public func pendingCleanupProfiles() throws -> Set<UUID> {
        let active = Set(try context.fetch(FetchDescriptor<PersistentTailscaleLocalState>()).map(\.profileID))
        return Set(try context.fetch(FetchDescriptor<PersistentTailscaleProfileCleanup>()).map(\.profileID))
            .subtracting(active)
    }

    public func completeCleanup(profileID: UUID) throws {
        try context.commit { try deleteCleanup(profileID) }
    }

    private func enqueueCleanup(_ profileID: UUID) throws {
        let query = FetchDescriptor<PersistentTailscaleProfileCleanup>(
            predicate: #Predicate { $0.profileID == profileID })
        if try context.fetch(query).isEmpty { context.insert(PersistentTailscaleProfileCleanup(profileID: profileID)) }
    }

    private func deleteCleanup(_ profileID: UUID) throws {
        let query = FetchDescriptor<PersistentTailscaleProfileCleanup>(
            predicate: #Predicate { $0.profileID == profileID })
        for row in try context.fetch(query) { context.delete(row) }
    }
}

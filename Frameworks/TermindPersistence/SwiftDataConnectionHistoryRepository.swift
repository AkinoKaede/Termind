import Foundation
import SwiftData
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@Model
public final class PersistentConnectionHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = ConnectionHistoryEntry.Kind.ssh.rawValue
    public var connectedAt = Date(timeIntervalSince1970: 0)

    public init(_ value: ConnectionHistoryEntry) {
        id = value.id
        hostID = value.hostID
        kind = value.kind.rawValue
        connectedAt = value.connectedAt
    }

    public var value: ConnectionHistoryEntry {
        ConnectionHistoryEntry(
            id: id, hostID: hostID,
            kind: ConnectionHistoryEntry.Kind(rawValue: kind) ?? .ssh,
            connectedAt: connectedAt
        )
    }
}

@MainActor
public final class SwiftDataConnectionHistoryRepository: ConnectionHistoryRepository {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func entries() throws -> [ConnectionHistoryEntry] {
        try context.fetch(
            FetchDescriptor<PersistentConnectionHistoryEntry>(
                sortBy: [SortDescriptor(\.connectedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    public func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        try context.commit {
            context.insert(PersistentConnectionHistoryEntry(entry))
        }
        try context.commit {
            var overflow = FetchDescriptor<PersistentConnectionHistoryEntry>(
                sortBy: [SortDescriptor(\.connectedAt, order: .reverse)]
            )
            overflow.fetchOffset = limit
            for row in try context.fetch(overflow) { context.delete(row) }
        }
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentConnectionHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { context.delete(row) }
        }
    }

    public func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentConnectionHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }

    public func clearAll() throws {
        try context.commit {
            try context.delete(model: PersistentConnectionHistoryEntry.self)
        }
    }
}

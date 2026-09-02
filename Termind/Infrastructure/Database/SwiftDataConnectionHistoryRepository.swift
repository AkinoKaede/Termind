import Foundation
import SwiftData

@Model
final class PersistentConnectionHistoryEntry {
    @Attribute(.unique) var id: UUID = UUID()
    var hostID: UUID = UUID()
    var kind = ConnectionHistoryEntry.Kind.ssh.rawValue
    var connectedAt = Date(timeIntervalSince1970: 0)

    init(_ value: ConnectionHistoryEntry) {
        id = value.id
        hostID = value.hostID
        kind = value.kind.rawValue
        connectedAt = value.connectedAt
    }

    var value: ConnectionHistoryEntry {
        ConnectionHistoryEntry(
            id: id, hostID: hostID,
            kind: ConnectionHistoryEntry.Kind(rawValue: kind) ?? .ssh,
            connectedAt: connectedAt
        )
    }
}

@MainActor
final class SwiftDataConnectionHistoryRepository: ConnectionHistoryRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func entries() throws -> [ConnectionHistoryEntry] {
        try context.fetch(
            FetchDescriptor<PersistentConnectionHistoryEntry>(
                sortBy: [SortDescriptor(\.connectedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
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

    func delete(_ id: ConnectionHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentConnectionHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { context.delete(row) }
        }
    }

    func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentConnectionHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }

    func clearAll() throws {
        try context.commit {
            try context.delete(model: PersistentConnectionHistoryEntry.self)
        }
    }
}

extension ConnectionHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataConnectionHistoryRepository(context: modelContext))
    }
}

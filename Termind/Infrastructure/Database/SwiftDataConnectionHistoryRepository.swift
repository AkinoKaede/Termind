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
        try context.fetch(FetchDescriptor<PersistentConnectionHistoryEntry>(
            sortBy: [SortDescriptor(\.connectedAt, order: .reverse)]
        )).map(\.value)
    }

    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        do {
            context.insert(PersistentConnectionHistoryEntry(entry))
            try context.save()

            var overflow = FetchDescriptor<PersistentConnectionHistoryEntry>(
                sortBy: [SortDescriptor(\.connectedAt, order: .reverse)]
            )
            overflow.fetchOffset = limit
            let oldRows = try context.fetch(overflow)
            if !oldRows.isEmpty {
                for row in oldRows { context.delete(row) }
                try context.save()
            }
        } catch { context.rollback(); throw error }
    }

    func delete(_ id: ConnectionHistoryEntry.ID) throws {
        do {
            var descriptor = FetchDescriptor<PersistentConnectionHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { context.delete(row) }
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func clear(for hostID: Host.ID) throws {
        do {
            try context.delete(
                model: PersistentConnectionHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
            try context.save()
        } catch { context.rollback(); throw error }
    }

    func clearAll() throws {
        do {
            try context.delete(model: PersistentConnectionHistoryEntry.self)
            try context.save()
        } catch { context.rollback(); throw error }
    }
}

extension ConnectionHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataConnectionHistoryRepository(context: modelContext))
    }
}

import Foundation
import SwiftData

@Model
final class PersistentCommandHistoryEntry {
    @Attribute(.unique) var id: UUID = UUID()
    var hostID: UUID = UUID()
    var command = ""
    var executedAt = Date(timeIntervalSince1970: 0)

    init(_ value: CommandHistoryEntry) {
        id = value.id
        hostID = value.hostID
        command = value.command
        executedAt = value.executedAt
    }

    var value: CommandHistoryEntry {
        CommandHistoryEntry(
            id: id, hostID: hostID, command: command, executedAt: executedAt
        )
    }
}

@MainActor
final class SwiftDataCommandHistoryRepository: CommandHistoryRepository {
    private let context: ModelContext

    init(context: ModelContext) { self.context = context }

    func entries(for hostID: Host.ID) throws -> [CommandHistoryEntry] {
        try context.fetch(FetchDescriptor<PersistentCommandHistoryEntry>(
            predicate: #Predicate { $0.hostID == hostID },
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
        )).map(\.value)
    }

    func insert(_ entry: CommandHistoryEntry, limit: Int) throws {
        try context.commit {
            let hostID = entry.hostID
            var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
            )
            descriptor.fetchOffset = max(0, limit - 1)
            for old in try context.fetch(descriptor) { context.delete(old) }
            context.insert(PersistentCommandHistoryEntry(entry))
        }
    }

    func delete(_ id: CommandHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let entry = try context.fetch(descriptor).first { context.delete(entry) }
        }
    }

    func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentCommandHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }
}

extension CommandHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataCommandHistoryRepository(context: modelContext))
    }
}

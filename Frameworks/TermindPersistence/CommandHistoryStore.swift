import Foundation
import SwiftData
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@MainActor
public final class SwiftDataCommandHistoryRepository: CommandHistoryRepository {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func entries(for hostID: Host.ID) throws -> [CommandHistoryEntry] {
        try context.fetch(
            FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    public func insert(_ entry: CommandHistoryEntry, limit: Int) throws {
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

    public func update(_ entry: CommandHistoryEntry) throws {
        let id = entry.id
        var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        guard let existing = try context.fetch(descriptor).first else { return }
        try context.commit { existing.apply(entry) }
    }

    public func delete(_ id: CommandHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let entry = try context.fetch(descriptor).first { context.delete(entry) }
        }
    }

    public func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentCommandHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }
}

import Foundation
import SwiftData
import TermindDomain
import TermindPersistence

import struct TermindDomain.Host

@MainActor
final class SwiftDataSFTPHistoryRepository: SFTPHistoryRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func entries(for hostID: Host.ID) throws -> [SFTPHistoryEntry] {
        try context.fetch(
            FetchDescriptor<PersistentSFTPHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    func upsert(_ entry: SFTPHistoryEntry, limit: Int) throws {
        let hostID = entry.hostID
        try context.commit {
            let rows = try context.fetch(
                FetchDescriptor<PersistentSFTPHistoryEntry>(
                    predicate: #Predicate { $0.hostID == hostID },
                    sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
                ))
            if let row = rows.first(where: {
                $0.kind == entry.kind.rawValue && $0.path == entry.path
            }) {
                row.visitedAt = entry.visitedAt
            } else {
                context.insert(PersistentSFTPHistoryEntry(entry))
            }
        }

        try context.commit {
            var overflow = FetchDescriptor<PersistentSFTPHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
            )
            overflow.fetchOffset = limit
            for row in try context.fetch(overflow) { context.delete(row) }
        }
    }

    func delete(_ id: SFTPHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentSFTPHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { context.delete(row) }
        }
    }

    func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentSFTPHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }
}

extension SFTPHistoryModel {
    convenience init(modelContext: ModelContext) {
        self.init(repository: SwiftDataSFTPHistoryRepository(context: modelContext))
    }
}

import Foundation
import SwiftData
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

@Model
public final class PersistentSFTPHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = SFTPHistoryEntry.Kind.directory.rawValue
    public var path = "/"
    public var visitedAt = Date(timeIntervalSince1970: 0)

    public init(_ value: SFTPHistoryEntry) {
        id = value.id
        hostID = value.hostID
        kind = value.kind.rawValue
        path = value.path
        visitedAt = value.visitedAt
    }

    public var value: SFTPHistoryEntry {
        SFTPHistoryEntry(
            id: id, hostID: hostID,
            kind: SFTPHistoryEntry.Kind(rawValue: kind) ?? .directory,
            path: path, visitedAt: visitedAt
        )
    }
}

@MainActor
public final class SwiftDataSFTPHistoryRepository: SFTPHistoryRepository {
    private let context: ModelContext

    public init(context: ModelContext) { self.context = context }

    public func entries(for hostID: Host.ID) throws -> [SFTPHistoryEntry] {
        try context.fetch(
            FetchDescriptor<PersistentSFTPHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.visitedAt, order: .reverse)]
            )
        ).map(\.value)
    }

    public func upsert(_ entry: SFTPHistoryEntry, limit: Int) throws {
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

    public func delete(_ id: SFTPHistoryEntry.ID) throws {
        try context.commit {
            var descriptor = FetchDescriptor<PersistentSFTPHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            if let row = try context.fetch(descriptor).first { context.delete(row) }
        }
    }

    public func clear(for hostID: Host.ID) throws {
        try context.commit {
            try context.delete(
                model: PersistentSFTPHistoryEntry.self,
                where: #Predicate { $0.hostID == hostID }
            )
        }
    }
}

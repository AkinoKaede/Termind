import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
public protocol SFTPHistoryRepository: AnyObject {
    func entries(for hostID: Host.ID) throws -> [SFTPHistoryEntry]
    func trim(to limit: Int) throws
    func upsert(_ entry: SFTPHistoryEntry, limit: Int) throws
    func delete(_ id: SFTPHistoryEntry.ID) throws
    func clear(for hostID: Host.ID) throws
}

@MainActor
public final class InMemorySFTPHistoryRepository: SFTPHistoryRepository {
    private var values: [SFTPHistoryEntry]

    public init(entries: [SFTPHistoryEntry] = []) { values = entries }

    public func entries(for hostID: Host.ID) throws -> [SFTPHistoryEntry] {
        values.filter { $0.hostID == hostID }.sorted { $0.visitedAt > $1.visitedAt }
    }

    public func trim(to limit: Int) throws {
        let entriesByHost = Dictionary(grouping: values, by: \.hostID)
        let retained = Set(
            entriesByHost.values.flatMap { entries in
                entries.sorted { $0.visitedAt > $1.visitedAt }.prefix(limit).map(\.id)
            })
        values.removeAll { !retained.contains($0.id) }
    }

    public func upsert(_ entry: SFTPHistoryEntry, limit: Int) throws {
        values.removeAll {
            $0.hostID == entry.hostID && $0.kind == entry.kind && $0.path == entry.path
        }
        values.append(entry)
        try trim(to: limit)
    }

    public func delete(_ id: SFTPHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    public func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }
}

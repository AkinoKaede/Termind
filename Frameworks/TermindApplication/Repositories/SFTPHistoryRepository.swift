import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
public protocol SFTPHistoryRepository: AnyObject {
    func entries(for hostID: Host.ID) throws -> [SFTPHistoryEntry]
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

    public func upsert(_ entry: SFTPHistoryEntry, limit: Int) throws {
        values.removeAll {
            $0.hostID == entry.hostID && $0.kind == entry.kind && $0.path == entry.path
        }
        values.append(entry)
        let retained = Set(try entries(for: entry.hostID).prefix(limit).map(\.id))
        values.removeAll { $0.hostID == entry.hostID && !retained.contains($0.id) }
    }

    public func delete(_ id: SFTPHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    public func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }
}

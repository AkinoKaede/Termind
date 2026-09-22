import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
public protocol ConnectionHistoryRepository: AnyObject {
    func entries() throws -> [ConnectionHistoryEntry]
    func trim(to limit: Int) throws
    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws
    func end(_ id: ConnectionHistoryEntry.ID, at date: Date) throws
    func delete(_ id: ConnectionHistoryEntry.ID) throws
    func clear(for hostID: Host.ID) throws
    func clearAll() throws
}

@MainActor
public final class InMemoryConnectionHistoryRepository: ConnectionHistoryRepository {
    private var values: [ConnectionHistoryEntry]

    public init(entries: [ConnectionHistoryEntry] = []) { values = entries }

    public func entries() throws -> [ConnectionHistoryEntry] {
        values.sorted(by: ConnectionHistoryEntry.isNewer)
    }

    public func trim(to limit: Int) throws {
        let retained = Set(try entries().prefix(limit).map(\.id))
        values.removeAll { !retained.contains($0.id) }
    }

    public func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        values.append(entry)
        try trim(to: limit)
    }

    public func end(_ id: ConnectionHistoryEntry.ID, at date: Date) throws {
        guard let index = values.firstIndex(where: { $0.id == id }), values[index].endedAt == nil else { return }
        values[index].endedAt = max(date, values[index].connectedAt)
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    public func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }

    public func clearAll() throws { values.removeAll() }
}

extension ConnectionHistoryEntry {
    public nonisolated static func isNewer(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.connectedAt != rhs.connectedAt { return lhs.connectedAt > rhs.connectedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

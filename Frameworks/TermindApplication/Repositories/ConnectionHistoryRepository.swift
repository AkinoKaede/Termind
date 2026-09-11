import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
public protocol ConnectionHistoryRepository: AnyObject {
    func entries() throws -> [ConnectionHistoryEntry]
    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws
    func delete(_ id: ConnectionHistoryEntry.ID) throws
    func clear(for hostID: Host.ID) throws
    func clearAll() throws
}

@MainActor
public final class InMemoryConnectionHistoryRepository: ConnectionHistoryRepository {
    private var values: [ConnectionHistoryEntry]

    public init(entries: [ConnectionHistoryEntry] = []) { values = entries }

    public func entries() throws -> [ConnectionHistoryEntry] {
        values.sorted { $0.connectedAt > $1.connectedAt }
    }

    public func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        values.append(entry)
        let retained = Set(try entries().prefix(limit).map(\.id))
        values.removeAll { !retained.contains($0.id) }
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    public func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }

    public func clearAll() throws { values.removeAll() }
}

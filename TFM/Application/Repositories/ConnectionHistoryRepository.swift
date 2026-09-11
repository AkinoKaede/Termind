import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
protocol ConnectionHistoryRepository: AnyObject {
    func entries() throws -> [ConnectionHistoryEntry]
    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws
    func delete(_ id: ConnectionHistoryEntry.ID) throws
    func clear(for hostID: Host.ID) throws
    func clearAll() throws
}

@MainActor
final class InMemoryConnectionHistoryRepository: ConnectionHistoryRepository {
    private var values: [ConnectionHistoryEntry]

    init(entries: [ConnectionHistoryEntry] = []) { values = entries }

    func entries() throws -> [ConnectionHistoryEntry] {
        values.sorted { $0.connectedAt > $1.connectedAt }
    }

    func insert(_ entry: ConnectionHistoryEntry, limit: Int) throws {
        values.append(entry)
        let retained = Set(try entries().prefix(limit).map(\.id))
        values.removeAll { !retained.contains($0.id) }
    }

    func delete(_ id: ConnectionHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }

    func clearAll() throws { values.removeAll() }
}

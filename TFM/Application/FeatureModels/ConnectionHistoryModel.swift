import Foundation
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
final class ConnectionHistoryModel {
    static let limit = 1_000

    private let repository: any ConnectionHistoryRepository
    private var cachedEntries: [ConnectionHistoryEntry]?
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [ConnectionHistoryEntry] = [],
        repository: (any ConnectionHistoryRepository)? = nil
    ) {
        self.repository =
            repository
            ?? InMemoryConnectionHistoryRepository(entries: entries)
    }

    func entries() -> [ConnectionHistoryEntry] {
        _ = revision
        if let cachedEntries { return cachedEntries }
        do {
            let values = try repository.entries()
            cachedEntries = values
            storageError = nil
            return values
        } catch {
            storageError = error.localizedDescription
            return []
        }
    }

    func entries(for hostID: Host.ID) -> [ConnectionHistoryEntry] {
        entries().filter { $0.hostID == hostID }
    }

    func mostRecentDate(for hostID: Host.ID) -> Date? {
        entries().first { $0.hostID == hostID }?.connectedAt
    }

    @discardableResult
    func record(
        kind: ConnectionHistoryEntry.Kind, for hostID: Host.ID,
        at date: Date = Date()
    ) -> ConnectionHistoryEntry? {
        let entry = ConnectionHistoryEntry(
            hostID: hostID, kind: kind, connectedAt: date
        )
        do {
            try repository.insert(entry, limit: Self.limit)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
            return entry
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    func delete(_ id: ConnectionHistoryEntry.ID) {
        do {
            try repository.delete(id)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }

    func clear(for hostID: Host.ID) {
        do {
            try repository.clear(for: hostID)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }

    func clearAll() {
        do {
            try repository.clearAll()
            cachedEntries = []
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }
}

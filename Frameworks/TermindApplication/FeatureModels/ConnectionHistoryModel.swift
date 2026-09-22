import Foundation
import Observation
import TermindDomain

import struct TermindDomain.Host

@MainActor
@Observable
public final class ConnectionHistoryModel {
    public static let limit = HistoryLimits.retainedEntries

    private let repository: any ConnectionHistoryRepository
    public let sourceDeviceID: UUID
    private var cachedEntries: [ConnectionHistoryEntry]?
    public private(set) var revision: UInt64 = 0
    public private(set) var storageError: String?

    public init(
        entries: [ConnectionHistoryEntry] = [],
        repository: (any ConnectionHistoryRepository)? = nil,
        sourceDeviceID: UUID = UUID()
    ) {
        self.repository = repository ?? InMemoryConnectionHistoryRepository(entries: entries)
        self.sourceDeviceID = sourceDeviceID
        do {
            try self.repository.trim(to: Self.limit)
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func entries() -> [ConnectionHistoryEntry] {
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

    public func entries(for hostID: Host.ID) -> [ConnectionHistoryEntry] {
        entries().filter { $0.hostID == hostID }
    }

    public func isLocal(_ entry: ConnectionHistoryEntry) -> Bool {
        entry.sourceDeviceID == sourceDeviceID
    }

    public func localEntries() -> [ConnectionHistoryEntry] {
        entries().filter(isLocal)
    }

    public func mostRecentDate(for hostID: Host.ID) -> Date? {
        entries().first { $0.hostID == hostID }?.connectedAt
    }

    public func mostRecentLocalDate(for hostID: Host.ID) -> Date? {
        localEntries().first { $0.hostID == hostID }?.connectedAt
    }

    @discardableResult
    public func record(
        kind: ConnectionHistoryEntry.Kind, for hostID: Host.ID,
        at date: Date = Date()
    ) -> ConnectionHistoryEntry? {
        let entry = ConnectionHistoryEntry(
            hostID: hostID, kind: kind, connectedAt: date,
            sourceDeviceID: sourceDeviceID
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

    public func end(_ id: ConnectionHistoryEntry.ID, at date: Date = Date()) {
        do {
            try repository.end(id, at: date)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }

    /// The sync coordinator persists remote events through its own transaction.
    /// Drop the presentation cache so the next read observes those committed rows.
    public func reload() {
        cachedEntries = nil
        storageError = nil
        revision &+= 1
    }

    public func delete(_ id: ConnectionHistoryEntry.ID) {
        do {
            try repository.delete(id)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }

    public func clear(for hostID: Host.ID) {
        do {
            try repository.clear(for: hostID)
            cachedEntries = nil
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }

    public func clearAll() {
        do {
            try repository.clearAll()
            cachedEntries = []
            storageError = nil
            revision &+= 1
        } catch { storageError = error.localizedDescription }
    }
}

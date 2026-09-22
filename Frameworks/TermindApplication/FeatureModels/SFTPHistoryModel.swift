import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Incremental persistence boundary for SFTP browse history.
///
/// Preview and focused-test instances use the in-memory projection. Each app
/// supplies a persistent repository so successful directory visits and file
/// downloads remain available across sessions without entering Vault sync.
@MainActor
@Observable
public final class SFTPHistoryModel {
    public static let perHostLimit = HistoryLimits.retainedEntries

    private let repository: any SFTPHistoryRepository
    public private(set) var revision: UInt64 = 0
    public private(set) var storageError: String?

    public init(
        entries: [SFTPHistoryEntry] = [],
        repository: (any SFTPHistoryRepository)? = nil
    ) {
        self.repository = repository ?? InMemorySFTPHistoryRepository(entries: entries)
        do {
            try self.repository.trim(to: Self.perHostLimit)
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func entries(for hostID: Host.ID, matching query: String = "") -> [SFTPHistoryEntry] {
        let values: [SFTPHistoryEntry]
        do {
            values = try repository.entries(for: hostID)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return []
        }
        guard !query.isEmpty else { return values }
        return values.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    public func record(
        kind: SFTPHistoryEntry.Kind, path: String, for hostID: Host.ID,
        at date: Date = Date()
    ) {
        let path = RemotePath.normalized(path)
        do {
            try repository.upsert(
                SFTPHistoryEntry(hostID: hostID, kind: kind, path: path, visitedAt: date),
                limit: Self.perHostLimit
            )
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func delete(_ id: SFTPHistoryEntry.ID) {
        do {
            try repository.delete(id)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }

    public func clear(for hostID: Host.ID) {
        do {
            try repository.clear(for: hostID)
            storageError = nil
            revision &+= 1
        } catch {
            storageError = error.localizedDescription
        }
    }
}

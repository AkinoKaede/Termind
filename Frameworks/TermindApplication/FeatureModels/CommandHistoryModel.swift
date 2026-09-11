import Foundation
import TermindDomain

import struct TermindDomain.Host

/// Incremental persistence boundary for terminal history.
///
/// Preview and focused-test instances use the in-memory projection. The app
/// supplies its SwiftData context so inserts and deletes touch only history
/// rows, independently of HostLibraryModel's compatibility snapshot persistence.
@MainActor
@Observable
public final class CommandHistoryModel {
    public static let perHostLimit = 1_000

    private let repository: any CommandHistoryRepository
    public private(set) var revision: UInt64 = 0
    public private(set) var storageError: String?

    public init(
        entries: [CommandHistoryEntry] = [],
        repository: (any CommandHistoryRepository)? = nil
    ) {
        self.repository = repository ?? InMemoryCommandHistoryRepository(entries: entries)
    }

    public func entries(for hostID: Host.ID, matching query: String = "") -> [CommandHistoryEntry] {
        let values: [CommandHistoryEntry]
        do {
            values = try repository.entries(for: hostID)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return []
        }
        guard !query.isEmpty else { return values }
        return values.filter { $0.command.localizedCaseInsensitiveContains(query) }
    }

    @discardableResult
    public func record(
        _ command: String, for hostID: Host.ID, at date: Date = Date()
    ) -> CommandHistoryEntry? {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let entry = CommandHistoryEntry(hostID: hostID, command: command, executedAt: date)
        do {
            try repository.insert(entry, limit: Self.perHostLimit)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return nil
        }
        revision &+= 1
        return entry
    }

    @discardableResult
    public func recordCompletion(
        for id: CommandHistoryEntry.ID, hostID: Host.ID,
        exitStatus: Int32, duration: TimeInterval?
    ) -> CommandHistoryEntry? {
        do {
            guard var entry = try repository.entries(for: hostID).first(where: { $0.id == id })
            else { return nil }
            entry.exitStatus = exitStatus
            entry.duration = duration.map { max(0, $0) }
            try repository.update(entry)
            storageError = nil
            revision &+= 1
            return entry
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    public func delete(_ id: CommandHistoryEntry.ID) {
        do {
            try repository.delete(id)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return
        }
        revision &+= 1
    }

    public func clear(for hostID: Host.ID) {
        do {
            try repository.clear(for: hostID)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return
        }
        revision &+= 1
    }

}

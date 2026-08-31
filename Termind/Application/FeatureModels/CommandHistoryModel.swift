import Foundation

/// Incremental persistence boundary for terminal history.
///
/// Preview and focused-test instances use the in-memory projection. The app
/// supplies its SwiftData context so inserts and deletes touch only history
/// rows, independently of HostLibraryModel's compatibility snapshot persistence.
@MainActor
@Observable
final class CommandHistoryModel {
    static let perHostLimit = 1_000

    private let repository: any CommandHistoryRepository
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [CommandHistoryEntry] = [],
        repository: (any CommandHistoryRepository)? = nil
    ) {
        self.repository = repository ?? InMemoryCommandHistoryRepository(entries: entries)
    }

    func entries(for hostID: Host.ID, matching query: String = "") -> [CommandHistoryEntry] {
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
    func record(
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
    func recordCompletion(
        for id: CommandHistoryEntry.ID, hostID: Host.ID,
        exitStatus: Int32, duration: TimeInterval
    ) -> CommandHistoryEntry? {
        do {
            guard var entry = try repository.entries(for: hostID).first(where: { $0.id == id })
            else { return nil }
            entry.exitStatus = exitStatus
            entry.duration = max(0, duration)
            try repository.update(entry)
            storageError = nil
            revision &+= 1
            return entry
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    func delete(_ id: CommandHistoryEntry.ID) {
        do {
            try repository.delete(id)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
            return
        }
        revision &+= 1
    }

    func clear(for hostID: Host.ID) {
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

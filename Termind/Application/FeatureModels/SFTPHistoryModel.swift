import Foundation

@MainActor
@Observable
final class SFTPHistoryModel {
    static let perHostLimit = 1_000

    private let repository: any SFTPHistoryRepository
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(
        entries: [SFTPHistoryEntry] = [],
        repository: (any SFTPHistoryRepository)? = nil
    ) {
        self.repository = repository ?? InMemorySFTPHistoryRepository(entries: entries)
    }

    func entries(for hostID: Host.ID, matching query: String = "") -> [SFTPHistoryEntry] {
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

    func record(
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

    func delete(_ id: SFTPHistoryEntry.ID) {
        do { try repository.delete(id); storageError = nil; revision &+= 1 }
        catch { storageError = error.localizedDescription }
    }

    func clear(for hostID: Host.ID) {
        do { try repository.clear(for: hostID); storageError = nil; revision &+= 1 }
        catch { storageError = error.localizedDescription }
    }
}

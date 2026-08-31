import Foundation

@MainActor
protocol CommandHistoryRepository: AnyObject {
    func entries(for hostID: Host.ID) throws -> [CommandHistoryEntry]
    func insert(_ entry: CommandHistoryEntry, limit: Int) throws
    func update(_ entry: CommandHistoryEntry) throws
    func delete(_ id: CommandHistoryEntry.ID) throws
    func clear(for hostID: Host.ID) throws
}

@MainActor
final class InMemoryCommandHistoryRepository: CommandHistoryRepository {
    private var values: [CommandHistoryEntry]

    init(entries: [CommandHistoryEntry] = []) { values = entries }

    func entries(for hostID: Host.ID) throws -> [CommandHistoryEntry] {
        values.filter { $0.hostID == hostID }.sorted { $0.executedAt > $1.executedAt }
    }

    func insert(_ entry: CommandHistoryEntry, limit: Int) throws {
        values.append(entry)
        let retained = Set(try entries(for: entry.hostID).prefix(limit).map(\.id))
        values.removeAll { $0.hostID == entry.hostID && !retained.contains($0.id) }
    }

    func update(_ entry: CommandHistoryEntry) throws {
        guard let index = values.firstIndex(where: { $0.id == entry.id }) else { return }
        values[index] = entry
    }

    func delete(_ id: CommandHistoryEntry.ID) throws {
        values.removeAll { $0.id == id }
    }

    func clear(for hostID: Host.ID) throws {
        values.removeAll { $0.hostID == hostID }
    }
}

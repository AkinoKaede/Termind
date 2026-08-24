import Foundation
import SwiftData

@Model
final class PersistentCommandHistoryEntry {
    @Attribute(.unique) var id: UUID = UUID()
    var hostID: UUID = UUID()
    var command = ""
    var executedAt = Date(timeIntervalSince1970: 0)

    init(_ value: CommandHistoryEntry) {
        id = value.id
        hostID = value.hostID
        command = value.command
        executedAt = value.executedAt
    }

    var value: CommandHistoryEntry {
        CommandHistoryEntry(
            id: id, hostID: hostID, command: command, executedAt: executedAt
        )
    }
}

/// Incremental persistence boundary for terminal history.
///
/// Preview and focused-test instances use the in-memory projection. The app
/// supplies its SwiftData context so inserts and deletes touch only history
/// rows, independently of HostStore's compatibility snapshot persistence.
@MainActor
@Observable
final class CommandHistoryStore {
    static let perHostLimit = 1_000

    private let context: ModelContext?
    private var memoryEntries: [CommandHistoryEntry]
    private(set) var revision: UInt64 = 0
    private(set) var storageError: String?

    init(entries: [CommandHistoryEntry] = []) {
        context = nil
        memoryEntries = entries
    }

    init(modelContext: ModelContext) {
        context = modelContext
        memoryEntries = []
    }

    func entries(for hostID: Host.ID, matching query: String = "") -> [CommandHistoryEntry] {
        let values: [CommandHistoryEntry]
        if let context {
            let descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.hostID == hostID },
                sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
            )
            do {
                values = try context.fetch(descriptor).map(\.value)
            } catch {
                storageError = error.localizedDescription
                return []
            }
        } else {
            values = memoryEntries
                .filter { $0.hostID == hostID }
                .sorted { $0.executedAt > $1.executedAt }
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
        if let context {
            do {
                try makeRoomForPersistedEntry(for: hostID, in: context)
                context.insert(PersistentCommandHistoryEntry(entry))
                try context.save()
                storageError = nil
            } catch {
                context.rollback()
                storageError = error.localizedDescription
                return nil
            }
        } else {
            memoryEntries.append(entry)
            let ordered = memoryEntries.filter { $0.hostID == hostID }
                .sorted { $0.executedAt > $1.executedAt }
            if ordered.count > Self.perHostLimit {
                let retained = Set(ordered.prefix(Self.perHostLimit).map(\.id))
                memoryEntries.removeAll {
                    $0.hostID == hostID && !retained.contains($0.id)
                }
            }
        }
        revision &+= 1
        return entry
    }

    func delete(_ id: CommandHistoryEntry.ID) {
        if let context {
            var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1
            do {
                if let entry = try context.fetch(descriptor).first { context.delete(entry) }
                try context.save()
                storageError = nil
            } catch {
                context.rollback()
                storageError = error.localizedDescription
                return
            }
        } else {
            memoryEntries.removeAll { $0.id == id }
        }
        revision &+= 1
    }

    func clear(for hostID: Host.ID) {
        if let context {
            do {
                try context.delete(
                    model: PersistentCommandHistoryEntry.self,
                    where: #Predicate { $0.hostID == hostID }
                )
                try context.save()
                storageError = nil
            } catch {
                context.rollback()
                storageError = error.localizedDescription
                return
            }
        } else {
            memoryEntries.removeAll { $0.hostID == hostID }
        }
        revision &+= 1
    }

    private func makeRoomForPersistedEntry(for hostID: Host.ID, in context: ModelContext) throws {
        var descriptor = FetchDescriptor<PersistentCommandHistoryEntry>(
            predicate: #Predicate { $0.hostID == hostID },
            sortBy: [SortDescriptor(\.executedAt, order: .reverse)]
        )
        descriptor.fetchOffset = Self.perHostLimit - 1
        for entry in try context.fetch(descriptor) { context.delete(entry) }
    }
}

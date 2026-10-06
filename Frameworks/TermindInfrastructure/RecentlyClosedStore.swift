import Foundation
import Observation

/// Local restoration metadata only. Each app owns one store across its windows.
@MainActor @Observable
public final class RecentlyClosedStore<Entry: Codable & Identifiable> where Entry.ID == UUID {
    public private(set) var entries: [Entry]
    public private(set) var storageError: String?
    private var persistentIDs: Set<UUID>
    private let defaults: UserDefaults?
    private let key: String
    private var canSave = true

    public init(defaults: UserDefaults?, key: String) {
        self.defaults = defaults
        self.key = key
        do {
            let entries = try defaults?.data(forKey: key).map { try JSONDecoder().decode([Entry].self, from: $0) } ?? []
            self.entries = Array(entries.prefix(15))
            persistentIDs = Set(entries.prefix(15).map(\.id))
        } catch {
            entries = []
            persistentIDs = []
            storageError = error.localizedDescription
            canSave = false
        }
    }

    public func record(_ entry: Entry, persist: Bool = true) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        entries = Array(entries.prefix(15))
        if persist { persistentIDs.insert(entry.id) } else { persistentIDs.remove(entry.id) }
        persistentIDs.formIntersection(entries.map(\.id))
        save()
    }

    public func update(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    public func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        persistentIDs.remove(id)
        save()
    }

    private func save() {
        guard canSave else { return }
        do {
            let data = try JSONEncoder().encode(entries.filter { persistentIDs.contains($0.id) })
            defaults?.set(data, forKey: key)
            storageError = nil
        } catch {
            storageError = error.localizedDescription
        }
    }
}

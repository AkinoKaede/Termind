import Foundation
import TermindDomain

/// Device-local connection intent only. Credentials, commands and live session state never enter this store.
@MainActor
final class MobileWorkspaceStore {
    static let key = "mobile.workspaces.v1"

    private struct Snapshot: Codable {
        var version = 1
        var workspaces: [MobileWorkspaceDescriptor]
    }

    private struct LegacyWorkspace: Decodable {
        var id: UUID
        var hostID: UUID
        var title: String
        var kind: ConnectionHistoryEntry.Kind
        var duplicateIndex: Int?
    }

    private enum StoreError: Error { case invalidSnapshot }

    private let defaults: UserDefaults?
    private var canSave = true

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() throws -> [MobileWorkspaceDescriptor] {
        do {
            guard let value = defaults?.object(forKey: Self.key) else {
                canSave = true
                return []
            }
            guard let data = value as? Data else { throw StoreError.invalidSnapshot }
            let decoder = JSONDecoder()
            let snapshot: Snapshot
            let needsMigration: Bool
            if let current = try? decoder.decode(Snapshot.self, from: data) {
                snapshot = current
                needsMigration = false
            } else {
                let legacy = try decoder.decode([LegacyWorkspace].self, from: data)
                var migrated: [MobileWorkspaceDescriptor] = []
                for entry in legacy {
                    // Reserve explicit indices too, including those later in the array.
                    let taken = Set(
                        legacy.filter { $0.hostID == entry.hostID && $0.kind == entry.kind }
                            .compactMap(\.duplicateIndex)
                            + migrated.filter { $0.hostID == entry.hostID && $0.kind == entry.kind }
                            .map(\.duplicateIndex))
                    var index = entry.duplicateIndex ?? 0
                    if entry.duplicateIndex == nil {
                        while taken.contains(index) { index += 1 }
                    }
                    migrated.append(
                        MobileWorkspaceDescriptor(
                            id: entry.id, hostID: entry.hostID, title: entry.title,
                            kind: entry.kind, duplicateIndex: index))
                }
                snapshot = Snapshot(workspaces: migrated)
                needsMigration = true
            }
            guard snapshot.version == 1,
                Set(snapshot.workspaces.map(\.id)).count == snapshot.workspaces.count,
                snapshot.workspaces.allSatisfy({ $0.duplicateIndex >= 0 })
            else { throw StoreError.invalidSnapshot }
            canSave = true
            if needsMigration { try save(snapshot.workspaces) }
            return snapshot.workspaces
        } catch {
            // Keep the original bytes for recovery instead of replacing an unreadable snapshot with an empty list.
            canSave = false
            throw error
        }
    }

    func save(_ workspaces: [MobileWorkspaceDescriptor]) throws {
        guard canSave else { throw StoreError.invalidSnapshot }
        guard let defaults else { return }
        defaults.set(try JSONEncoder().encode(Snapshot(workspaces: workspaces)), forKey: Self.key)
    }
}

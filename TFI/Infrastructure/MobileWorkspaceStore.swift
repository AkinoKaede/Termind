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
                snapshot = Snapshot(
                    workspaces: legacy.map {
                        MobileWorkspaceDescriptor(id: $0.id, hostID: $0.hostID, title: $0.title, kind: $0.kind)
                    })
                needsMigration = true
            }
            guard snapshot.version == 1,
                Set(snapshot.workspaces.map(\.id)).count == snapshot.workspaces.count
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

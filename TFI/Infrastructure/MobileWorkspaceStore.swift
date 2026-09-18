import Foundation

/// Device-local connection intent only. Credentials, commands and live session state never enter this store.
@MainActor
final class MobileWorkspaceStore {
    static let key = "mobile.workspaces.v1"

    private struct Snapshot: Codable {
        var version = 1
        var workspaces: [MobileWorkspaceDescriptor]
    }

    private enum StoreError: Error { case invalidSnapshot }

    private let defaults: UserDefaults?
    private var canSave = true

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    func load() throws -> [MobileWorkspaceDescriptor] {
        do {
            guard let value = defaults?.object(forKey: Self.key) else { return [] }
            guard let data = value as? Data else { throw StoreError.invalidSnapshot }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1,
                Set(snapshot.workspaces.map(\.id)).count == snapshot.workspaces.count,
                snapshot.workspaces.allSatisfy({ $0.duplicateIndex >= 0 })
            else { throw StoreError.invalidSnapshot }
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

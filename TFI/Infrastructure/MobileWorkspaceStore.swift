import Foundation

/// Retire local workspace snapshots without migrating them into a new cache.
@MainActor
enum MobileWorkspaceStore {
    static let key = "mobile.workspaces.v1"
    static let recentlyClosedKey = "mobile.recentlyClosed.v2"

    static func retire(in defaults: UserDefaults) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: recentlyClosedKey)
    }
}

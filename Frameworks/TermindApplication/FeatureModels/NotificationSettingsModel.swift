import Foundation
import TermindDomain

/// Settings edits persist first, then update every notification source.
@Observable
public final class NotificationSettingsModel {
    public private(set) var preferences = NotificationPreferences()
    public private(set) var storageError: String?
    private let persistence: (any NotificationPreferencesPersisting)?

    public init(persistence: (any NotificationPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadNotificationPreferences() } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set<Value>(_ value: Value, for keyPath: WritableKeyPath<NotificationPreferences, Value>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        guard next.isValid else { return false }
        guard next != preferences else { return true }
        do {
            try persistence?.saveNotificationPreferences(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: NotificationPreferences) {
        preferences = value
        storageError = nil
    }
}

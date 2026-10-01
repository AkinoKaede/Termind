import Foundation
import TermindDomain

/// Settings edits persist first, then update every window and the terminal runtime.
@Observable
public final class TerminalSettingsModel {
    public private(set) var preferences = TerminalPreferences()
    public private(set) var storageError: String?
    private let persistence: (any TerminalPreferencesPersisting)?

    public init(persistence: (any TerminalPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadTerminal() } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set<Value>(_ value: Value, for keyPath: WritableKeyPath<TerminalPreferences, Value>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        return save(next)
    }

    /// A theme choice is one persisted edit, including disabling the custom overlay.
    @discardableResult
    public func selectTheme(named name: String, isDark: Bool) -> Bool {
        var next = preferences
        if isDark {
            next.darkTheme = name
            next.darkCustomEnabled = false
        } else {
            next.lightTheme = name
            next.lightCustomEnabled = false
        }
        return save(next)
    }

    @discardableResult
    public func selectCustomTheme(isDark: Bool) -> Bool {
        set(true, for: isDark ? \.darkCustomEnabled : \.lightCustomEnabled)
    }

    private func save(_ next: TerminalPreferences) -> Bool {
        guard next != preferences else { return true }
        do {
            try persistence?.saveTerminal(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: TerminalPreferences) {
        preferences = value
        storageError = nil
    }
}

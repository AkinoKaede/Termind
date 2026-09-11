import Foundation
import TermindDomain

/// Settings edits persist first, then update every window and the terminal runtime.
@Observable
public final class TerminalSettingsModel {
    public private(set) var preferences = TerminalPreferences()
    public private(set) var storageError: String?
    private let persistence: (any TerminalPreferencesPersisting)?
    public var didChangeShellIntegration: ((Bool) -> Void)?

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
        let previous = preferences
        preferences = value
        storageError = nil
        if previous.shellIntegration != value.shellIntegration {
            didChangeShellIntegration?(value.shellIntegration)
        }
    }
}

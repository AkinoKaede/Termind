import Foundation
import TermindDomain

@Observable
public final class TerminalHighlightSettingsModel {
    public private(set) var preferences = TerminalHighlightPreferences()
    public private(set) var storageError: String?
    private let persistence: (any TerminalHighlightPreferencesPersisting)?

    public init(persistence: (any TerminalHighlightPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadTerminalHighlightPreferences() } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func save(_ next: TerminalHighlightPreferences) -> Bool {
        guard next.isValid else { return false }
        guard next != preferences else { return true }
        do {
            try persistence?.saveTerminalHighlightPreferences(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func upsert(_ rule: TerminalHighlightRule, validate: (TerminalHighlightRule) -> Bool) -> Bool {
        guard !rule.isBuiltIn, rule.isValid, validate(rule) else { return false }
        var next = preferences
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index] = rule
        } else {
            next.rules.append(rule)
        }
        return save(next)
    }

    public func applyRemoteSnapshot(_ value: TerminalHighlightPreferences) {
        guard value.isValid else { return }
        preferences = value
        storageError = nil
    }
}

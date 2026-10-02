import Foundation
import TermindDomain

@Observable
public final class TerminalHighlightSettingsModel {
    public enum ValidationIssue: Equatable {
        case builtIn
        case invalidRule
        case invalidPattern(String)
        case ruleLimit
    }

    public enum Failure: Equatable {
        case validation(ValidationIssue)
        case storage(String)
    }

    public private(set) var preferences = TerminalHighlightPreferences()
    public private(set) var failure: Failure?
    private let persistence: (any TerminalHighlightPreferencesPersisting)?
    private let validatePattern: @MainActor (TerminalHighlightRule) -> String?

    public init(
        persistence: (any TerminalHighlightPreferencesPersisting)? = nil,
        validatePattern: @escaping @MainActor (TerminalHighlightRule) -> String? = { _ in nil }
    ) {
        self.persistence = persistence
        self.validatePattern = validatePattern
        do { if let persistence { preferences = try persistence.loadTerminalHighlightPreferences() } } catch {
            failure = .storage(error.localizedDescription)
        }
    }

    public var storageError: String? {
        if case .storage(let message) = failure { message } else { nil }
    }

    public var canAddRule: Bool { preferences.rules.count < TerminalHighlightPreferences.maximumCustomRuleCount }

    public func validationIssue(for rule: TerminalHighlightRule) -> ValidationIssue? {
        if rule.isBuiltIn { return .builtIn }
        if !rule.isValid { return .invalidRule }
        if let issue = patternValidationIssue(for: rule) { return .invalidPattern(issue) }
        if !canAddRule && !preferences.rules.contains(where: { $0.id == rule.id }) { return .ruleLimit }
        return nil
    }

    public func patternValidationIssue(for rule: TerminalHighlightRule) -> String? {
        rule.pattern.isEmpty ? nil : validatePattern(rule)
    }

    @discardableResult
    private func save(_ next: TerminalHighlightPreferences) -> Bool {
        guard next.isValid else {
            failure = .validation(.invalidRule)
            return false
        }
        guard next != preferences else {
            failure = nil
            return true
        }
        do {
            try persistence?.saveTerminalHighlightPreferences(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            failure = .storage(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) -> Bool {
        var next = preferences
        next.isEnabled = enabled
        return save(next)
    }

    @discardableResult
    public func upsert(_ rule: TerminalHighlightRule) -> Bool {
        if let issue = validationIssue(for: rule) {
            failure = .validation(issue)
            return false
        }
        var next = preferences
        if let index = next.rules.firstIndex(where: { $0.id == rule.id }) {
            next.rules[index] = rule
        } else {
            next.rules.append(rule)
        }
        return save(next)
    }

    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        var next = preferences
        next.rules.removeAll { $0.id == id }
        return save(next)
    }

    public func canMove(_ id: UUID, by offset: Int) -> Bool {
        guard let index = preferences.rules.firstIndex(where: { $0.id == id }) else { return false }
        return preferences.rules.indices.contains(index + offset)
    }

    @discardableResult
    public func move(_ id: UUID, by offset: Int) -> Bool {
        guard canMove(id, by: offset), let index = preferences.rules.firstIndex(where: { $0.id == id }) else {
            return false
        }
        var next = preferences
        next.rules.swapAt(index, index + offset)
        return save(next)
    }

    @discardableResult
    public func move(fromOffsets indices: IndexSet, toOffset destination: Int) -> Bool {
        guard indices.allSatisfy(preferences.rules.indices.contains),
            (0...preferences.rules.count).contains(destination)
        else { return false }
        var next = preferences
        let moved = indices.map { next.rules[$0] }
        for index in indices.reversed() { next.rules.remove(at: index) }
        let insertion = destination - indices.filter { $0 < destination }.count
        next.rules.insert(contentsOf: moved, at: insertion)
        return save(next)
    }

    public func applyRemoteSnapshot(_ value: TerminalHighlightPreferences) {
        guard value.isValid else { return }
        preferences = value
        failure = nil
    }
}

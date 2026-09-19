import Foundation
import TermindDomain

/// Persists SSH limits before applying them to live connection admission.
@Observable
public final class SSHSettingsModel {
    public private(set) var preferences = SSHPreferences()
    public private(set) var storageError: String?
    private let persistence: (any SSHPreferencesPersisting)?
    public var didChange: ((SSHPreferences) -> Void)?

    public init(persistence: (any SSHPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadSSH().normalized } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set(_ value: Int, for keyPath: WritableKeyPath<SSHPreferences, Int>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        next = next.normalized
        guard next != preferences else { return true }
        do {
            try persistence?.saveSSH(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: SSHPreferences) {
        let next = value.normalized
        let changed = preferences != next
        preferences = next
        storageError = nil
        if changed { didChange?(next) }
    }
}

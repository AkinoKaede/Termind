import Foundation
import TermindDomain

/// Persist settings before changing the controls or the application-wide transfer queue.
@Observable
public final class SFTPSettingsModel {
    public private(set) var preferences = SFTPPreferences()
    public private(set) var storageError: String?
    private let persistence: (any SFTPPreferencesPersisting)?
    public var didChange: ((SFTPPreferences) -> Void)?

    public init(persistence: (any SFTPPreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadSFTP().normalized } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func set(_ value: Int, for keyPath: WritableKeyPath<SFTPPreferences, Int>) -> Bool {
        var next = preferences
        next[keyPath: keyPath] = value
        next = next.normalized
        guard next != preferences else { return true }
        do {
            try persistence?.saveSFTP(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: SFTPPreferences) {
        let next = value.normalized
        let changed = preferences != next
        preferences = next
        storageError = nil
        if changed { didChange?(next) }
    }
}

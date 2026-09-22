import Foundation
import TermindDomain

@Observable
public final class WorkspaceSettingsModel {
    public private(set) var preferences = WorkspacePreferences()
    public private(set) var storageError: String?
    private let persistence: (any WorkspacePreferencesPersisting)?

    public init(persistence: (any WorkspacePreferencesPersisting)? = nil) {
        self.persistence = persistence
        do { if let persistence { preferences = try persistence.loadWorkspacePreferences() } } catch {
            storageError = error.localizedDescription
        }
    }

    @discardableResult
    public func setAutomaticRenaming(_ enabled: Bool) -> Bool {
        var next = preferences
        next.automaticallyRenamesWorkspaces = enabled
        guard next != preferences else { return true }
        do {
            try persistence?.saveWorkspacePreferences(next)
            applyRemoteSnapshot(next)
            return true
        } catch {
            storageError = error.localizedDescription
            return false
        }
    }

    public func applyRemoteSnapshot(_ value: WorkspacePreferences) {
        preferences = value
        storageError = nil
    }
}

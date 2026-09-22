import Foundation
import TermindDomain

@MainActor
public protocol WorkspacePreferencesPersisting: AnyObject {
    func loadWorkspacePreferences() throws -> WorkspacePreferences
    func saveWorkspacePreferences(_ value: WorkspacePreferences) throws
}

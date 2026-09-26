@testable import TermindIOS

extension MobileAppModel {
    /// Single-window fixtures use an explicit stable session so relaunch assertions retain ownership.
    @MainActor var testWorkspaceSession: MobileWorkspaceSessionModel { workspaceSession(for: "test") }
}

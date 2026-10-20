// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

@testable import TermindIOS

extension MobileAppModel {
    /// Single-window fixtures use an explicit stable session so relaunch assertions retain ownership.
    @MainActor var testWorkspaceSession: MobileWorkspaceSessionModel { workspaceSession(for: "test") }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
public protocol WorkspacePreferencesPersisting: AnyObject {
    func loadWorkspacePreferences() throws -> WorkspacePreferences
    func saveWorkspacePreferences(_ value: WorkspacePreferences) throws
}

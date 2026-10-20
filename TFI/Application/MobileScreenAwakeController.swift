// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

@MainActor
final class MobileScreenAwakeController {
    private var requestingScenes: Set<UUID> = []
    private let setIdleTimerDisabled: @MainActor (Bool) -> Void

    init(setIdleTimerDisabled: @escaping @MainActor (Bool) -> Void) {
        self.setIdleTimerDisabled = setIdleTimerDisabled
    }

    static func wantsAwake(
        preferences: TerminalExperiencePreferences, isActive: Bool, workspaceKind: ConnectionHistoryEntry.Kind?
    ) -> Bool {
        preferences.keepScreenAwake && isActive && workspaceKind != nil && workspaceKind != .sftp
    }

    func update(sceneID: UUID, wantsAwake: Bool) {
        let wasAwake = !requestingScenes.isEmpty
        if wantsAwake {
            requestingScenes.insert(sceneID)
        } else {
            requestingScenes.remove(sceneID)
        }
        let isAwake = !requestingScenes.isEmpty
        if wasAwake != isAwake { setIdleTimerDisabled(isAwake) }
    }
}

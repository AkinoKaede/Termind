// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

extension AppStrings {
    public nonisolated enum History {
        public static var showHistory: LocalizedStringResource { "Show History" }
        public static var recentClosed: LocalizedStringResource { "Recently Closed" }
        public static var reopenWindow: LocalizedStringResource { "Reopen Window" }
        public static func closedWindow(_ title: String, count: Int) -> LocalizedStringResource {
            if count <= 1 { return LocalizedStringResource("\(title)") }
            if count == 2 { return "\(title) (and 1 more workspace)" }
            return "\(title) (and \(count - 1) more workspaces)"
        }
        public static var earlierToday: LocalizedStringResource { "Earlier Today" }
    }
}

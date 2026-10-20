// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Device-local typography, deliberately separate from synced terminal preferences.
public nonisolated struct TerminalFontPreferences: Hashable, Sendable {
    public var family: String
    public var size: Double
    public var sizeFollowsTheme: Bool

    public init(family: String = "", size: Double = 12, sizeFollowsTheme: Bool = true) {
        self.family = family
        self.size = size
        self.sizeFollowsTheme = sizeFollowsTheme
    }

    public func resolvingFamily(in availableFamilies: [String]) -> Self {
        var resolved = self
        if !availableFamilies.contains(family) { resolved.family = "" }
        return resolved
    }
}

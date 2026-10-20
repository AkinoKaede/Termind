// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

nonisolated

    extension Snippet
{
    public func duplicated() -> Snippet {
        var copy = self
        copy.id = UUID()
        copy.title = String(localized: "\(title) Copy")
        copy.sortIndex = 0
        return copy
    }
}

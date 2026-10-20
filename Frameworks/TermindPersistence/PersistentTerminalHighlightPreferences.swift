// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData

/// Frozen V46–V51 storage shape, used only to migrate old stores. V52 removes this entity.
@Model
public final class PersistentTerminalHighlightPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(data: Data = Data()) { self.data = data }
}

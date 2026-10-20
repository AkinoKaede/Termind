// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData

@Model
public final class PersistentAISecretLocation {
    @Attribute(.unique) public var reference = ""
    public var usesICloud = false
    public var pendingDeletion = false
    public init(reference: String) { self.reference = reference }
}

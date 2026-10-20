// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// A synchronized display record for one stable Termind installation.
///
/// Features store only the installation ID and resolve its current display name
/// through the shared device directory.
public nonisolated struct DeviceRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var displayName: String

    public init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData

@Model
public final class PersistentSFTPHistoryEntry {
    @Attribute(.unique) public var id: UUID = UUID()
    public var hostID: UUID = UUID()
    public var kind = "directory"
    public var path = "/"
    public var visitedAt = Date(timeIntervalSince1970: 0)

    public init(hostID: UUID, kind: String, path: String, visitedAt: Date) {
        self.hostID = hostID
        self.kind = kind
        self.path = path
        self.visitedAt = visitedAt
    }
}

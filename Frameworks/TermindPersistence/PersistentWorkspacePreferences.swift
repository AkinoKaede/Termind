// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentWorkspacePreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: WorkspacePreferences) throws { try apply(value) }
    public func load() throws -> WorkspacePreferences {
        try JSONDecoder().decode(WorkspacePreferences.self, from: data)
    }
    public func apply(_ value: WorkspacePreferences) throws { data = try JSONEncoder().encode(value) }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentTerminalPreferences {
    @Attribute(.unique) public var key = "default"
    public var data = Data()

    public init(_ value: TerminalPreferences) throws { try apply(value) }
    public func load() throws -> TerminalPreferences { try JSONDecoder().decode(TerminalPreferences.self, from: data) }
    public func apply(_ value: TerminalPreferences) throws { data = try JSONEncoder().encode(value) }
}

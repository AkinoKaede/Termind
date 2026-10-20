// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData

/// Additive backing keeps the published PersistentAgentSkill schema unchanged.
@Model
public final class PersistentSkillPackage {
    @Attribute(.unique) public var skillID: UUID = UUID()
    public var data = Data()

    public init(skillID: UUID, package: AgentSkillPackage) throws {
        self.skillID = skillID
        data = try JSONEncoder().encode(package)
    }

    public func value() throws -> AgentSkillPackage {
        try JSONDecoder().decode(AgentSkillPackage.self, from: data)
    }
}

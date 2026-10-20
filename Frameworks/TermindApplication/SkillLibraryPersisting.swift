// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

@MainActor
public protocol SkillLibraryPersisting: AnyObject {
    func load() throws -> [AgentSkill]
    func save(_ skills: [AgentSkill]) throws
}

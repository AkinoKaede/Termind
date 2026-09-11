import AgentKit
import Foundation
import SwiftData
import TermindPersistence

/// Local storage for the skill library.
///
/// Delete-and-rewrite, following `AIPersistence.save`: the library is a short,
/// wholly-owned list, and a diff would be more code to get wrong than the write
/// it saves. Its own store rather than a fourth field on the AI snapshot, so
/// editing one skill does not rewrite every provider and model row.
@MainActor
final class SkillPersistence {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func load() throws -> [AgentSkill] {
        let rows = try context.fetch(
            FetchDescriptor<PersistentAgentSkill>(sortBy: [SortDescriptor(\.sortIndex)])
        )
        var seen: Set<UUID> = []
        return rows.compactMap { row in
            guard seen.insert(row.id).inserted else { return nil }
            return row.value
        }
    }

    func save(_ skills: [AgentSkill]) throws {
        try context.commit { try replace(skills) }
    }

    /// Stages rows in the caller-owned transaction.
    func replace(_ skills: [AgentSkill]) throws {
        try context.delete(model: PersistentAgentSkill.self)
        for (index, skill) in skills.enumerated() {
            context.insert(PersistentAgentSkill(skill, sortIndex: index))
        }
    }
}

extension SkillPersistence: SkillLibraryPersisting {}

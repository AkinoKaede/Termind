import AgentKit
import Foundation
import SwiftData

@Model
final class PersistentAgentSkill {
    @Attribute(.unique) var id: UUID = UUID()
    var name = ""
    var title = ""
    var summary = ""
    var body = ""
    var isEnabled = true
    var importedFrom = ""
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var sortIndex = 0

    init(_ value: AgentSkill, sortIndex: Int) {
        id = value.id
        name = value.name
        title = value.title
        summary = value.summary
        body = value.body
        isEnabled = value.isEnabled
        importedFrom = value.importedFrom
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        self.sortIndex = sortIndex
    }

    var value: AgentSkill {
        AgentSkill(
            id: id, name: name, title: title, summary: summary, body: body,
            isEnabled: isEnabled, importedFrom: importedFrom,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }
}

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

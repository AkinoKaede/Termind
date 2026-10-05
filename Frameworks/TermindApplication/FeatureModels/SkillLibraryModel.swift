import AgentKit
import Foundation

/// The skills the user has installed.
///
/// Its own store rather than more fields on `AIConfigurationModel`: that one is
/// about endpoints you spend a key at, and this is a library of documents. They
/// share nothing but the Settings page they appear on.
///
/// Settings and authorized skill tools share this atomic persistence boundary.
@Observable @MainActor
public final class SkillLibraryModel: AgentSkillLibraryManaging {
    public private(set) var skills: [AgentSkill] = []
    public private(set) var storageError: String?

    private var persistence: (any SkillLibraryPersisting)?

    public init(
        skills: [AgentSkill] = [],
        persistence: (any SkillLibraryPersisting)? = nil
    ) {
        self.skills = skills
        self.persistence = persistence
        guard let persistence else { return }
        do {
            self.skills = try persistence.load()
        } catch {
            storageError = error.localizedDescription
        }
    }

    // MARK: - Reads

    /// What a run may be offered. Incomplete drafts are excluded rather than
    /// listed as names with nothing to match on — see `AgentSkill.isComplete`.
    public var enabledSkills: [AgentSkill] {
        let conflicts = conflictingSkillIDs
        return AgentSkillLibrary.builtIns
            + skills.filter { $0.isEnabled && $0.isComplete && !conflicts.contains($0.id) }
    }

    /// Runtime-only inventory includes the immutable application skills.
    public var inventory: [AgentSkill] { AgentSkillLibrary.builtIns + skills }
    public var snapshot: AgentSkillLibrarySnapshot {
        AgentSkillLibrarySnapshot(inventory, readOnlyNames: AgentSkillLibrary.reservedNames)
    }

    public var catalog: AgentSkillCatalog { AgentSkillCatalog(enabledSkills) }

    public func skill(_ id: AgentSkill.ID) -> AgentSkill? {
        skills.first { $0.id == id }
    }

    public func hasNameConflict(_ name: String, excluding id: AgentSkill.ID) -> Bool {
        !name.isEmpty
            && (AgentSkillLibrary.reservedNames.contains(name)
                || skills.contains { $0.id != id && $0.effectiveName == name })
    }

    public var conflictingSkillIDs: Set<UUID> {
        var names = AgentSkillLibrary.reservedNames
        var conflicts = Set<UUID>()
        for skill in skills.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            if !skill.effectiveName.isEmpty, !names.insert(skill.effectiveName).inserted {
                conflicts.insert(skill.id)
            }
        }
        return conflicts
    }

    /// Only the trusted persistence/sync composition root supplies this snapshot.
    public func applyRemoteSnapshot(_ values: [AgentSkill]) {
        skills = values
        storageError = nil
    }

    public func skillSnapshot() async throws -> AgentSkillLibrarySnapshot {
        if let storageError { throw AgentToolError.invalidArguments(storageError) }
        return snapshot
    }

    public func applySkillOperations(_ operations: [AgentSkillOperation], expectedRevision: String) async throws {
        try Task.checkCancellation()
        guard snapshot.revision == expectedRevision else {
            throw AgentToolError.invalidArguments("The skill library changed after review. Read it again and retry.")
        }
        let updated = try AgentSkillOperation.applying(
            operations, to: skills, readOnlyNames: AgentSkillLibrary.reservedNames)
        try persistence?.save(updated)
        skills = updated
        storageError = nil
    }

    public func installSkill(_ skill: AgentSkill, expectedRevision: String) async throws {
        try Task.checkCancellation()
        guard snapshot.revision == expectedRevision else {
            throw AgentToolError.invalidArguments("The skill library changed after review. Read it again and retry.")
        }
        _ = try snapshot.adding(skill)
        let updated = skills + [skill]
        try persistence?.save(updated)
        skills = updated
        storageError = nil
    }

    // MARK: - Writes

    public func upsert(_ skill: AgentSkill) {
        guard !AgentSkillLibrary.reservedNames.contains(skill.name) else {
            storageError = String(localized: "This skill name is reserved for a built-in skill.")
            return
        }
        mutatePersistedState {
            var updated = skill
            updated.updatedAt = .now
            if let index = skills.firstIndex(where: { $0.id == skill.id }) {
                skills[index] = updated
            } else {
                skills.append(updated)
            }
        }
    }

    /// Locks a valid, unique derived name without changing the UUID identity.
    /// The same move `AIConfigurationModel.lockMCPNamespace` makes, and for the
    /// same reason: the model-facing identifier must stop moving once anything
    /// could have referred to it.
    @discardableResult
    public func lockName(for id: AgentSkill.ID) -> Bool {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return false }
        if !skills[index].name.isEmpty { return true }
        let name = skills[index].effectiveName
        guard AgentSkillNaming.isValid(name), !hasNameConflict(name, excluding: id) else {
            return false
        }
        return mutatePersistedState { skills[index].name = name }
    }

    @discardableResult
    public func renameConflictingSkill(_ id: UUID, to name: String) -> Bool {
        guard var skill = skill(id), hasNameConflict(skill.effectiveName, excluding: id),
            AgentSkillNaming.isValid(name), !hasNameConflict(name, excluding: id)
        else { return false }
        skill.name = name
        upsert(skill)
        return storageError == nil
    }

    public func delete(id: AgentSkill.ID) {
        mutatePersistedState { skills.removeAll { $0.id == id } }
    }

    public func setEnabled(_ enabled: Bool, for id: AgentSkill.ID) {
        mutatePersistedState {
            guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
            skills[index].isEnabled = enabled
            skills[index].updatedAt = .now
        }
    }

    /// Adds an imported document under a name that is free.
    ///
    /// A collision is resolved rather than refused: someone importing a second
    /// `pdf-processing` from another collection wants both, and a numbered name
    /// is a smaller surprise than a silent overwrite of the one they had.
    @discardableResult
    public func install(_ document: AgentSkillDocument, importedFrom: String) -> AgentSkill {
        let skill = AgentSkill(
            name: availableName(basedOn: document.name),
            title: Self.title(of: document),
            summary: document.description,
            body: document.body,
            importedFrom: importedFrom, package: document.package
        )
        upsert(skill)
        return skill
    }

    private func availableName(basedOn name: String) -> String {
        var candidate = name
        var suffix = 2
        while AgentSkillLibrary.reservedNames.contains(candidate)
            || skills.contains(where: { $0.effectiveName == candidate })
        {
            let room = AgentSkillNaming.maximumLength - "-\(suffix)".count
            candidate = "\(name.prefix(room))-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// The document's first Markdown heading, which is where a skill written for
    /// the standard puts its human-facing name — the format itself has no title
    /// field. Falls back to the name.
    private static func title(of document: AgentSkillDocument) -> String {
        for line in document.body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else {
                if trimmed.isEmpty { continue }
                break
            }
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }
        return document.name
    }

    // MARK: - Persistence

    /// Mutate, save, and put it back if the save failed. Lifted from
    /// `AIConfigurationModel.mutatePersistedState`: observable state that
    /// survived a failed write is state the user would go on editing.
    @discardableResult
    private func mutatePersistedState(_ mutation: () -> Void) -> Bool {
        let previous = skills
        mutation()
        guard let persistence else {
            storageError = nil
            return true
        }
        do {
            try persistence.save(skills)
            storageError = nil
            return true
        } catch {
            skills = previous
            storageError = error.localizedDescription
            return false
        }
    }
}

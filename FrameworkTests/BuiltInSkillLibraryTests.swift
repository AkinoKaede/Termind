import AgentKit
import Foundation
import TermindApplication
import Testing

@Suite @MainActor struct BuiltInSkillLibraryTests {
    @Test func protectedSkillsAreReadableAndNeverWritten() async throws {
        let persistence = TestSkillPersistence()
        let library = SkillLibraryModel(persistence: persistence)
        let snapshot = try await library.skillSnapshot()
        #expect(snapshot.skills.map(\.name) == ["skill-creator", "skill-installer"])
        #expect(library.skills.isEmpty)
        let registry = AgentToolCatalog.registry(
            builtIn: .init(
                groups: [.skills], skills: library.catalog, skillInventory: library.inventory,
                readOnlySkillNames: AgentSkillLibrary.reservedNames, skillLibrary: library))
        let reader = try #require(registry["skill_read_file"])
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: .init(
                id: "read", name: "skill_read_file", arguments: .object(["name": .string("skill-creator")])))
        let context = AgentToolExecutionContext(
            runID: invocation.runID, userIntent: "Read", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(), preflightMetadata: [:], authorize: { _ in .allow })
        let result = try await reader.execute(invocation, context: context)
        #expect(result.content.contains("Skill Creator"))
        for name in AgentSkillLibrary.reservedNames {
            let operations = [AgentSkillOperation(action: .delete, name: name)]
            await #expect(throws: (any Error).self) {
                try await library.applySkillOperations(operations, expectedRevision: snapshot.revision)
            }
        }
        #expect(persistence.saves == 0)
    }

    @Test func userCollisionsRemainVisibleUntilRenamed() {
        let user = AgentSkill(name: "skill-creator", summary: "Mine", body: "My version")
        let library = SkillLibraryModel(skills: [user])
        #expect(library.skills == [user])
        #expect(library.conflictingSkillIDs == [user.id])
        #expect(library.catalog.skill(named: "skill-creator")?.id == AgentSkillLibrary.builtIns[0].id)
        #expect(library.renameConflictingSkill(user.id, to: "my-skill-creator"))
        #expect(library.skills[0].id == user.id)
        #expect(library.skills[0].body == user.body)
        #expect(library.catalog.names.contains("my-skill-creator"))
        #expect(library.conflictingSkillIDs.isEmpty)
    }

    @Test func eitherUserRecordInANameCollisionCanBeRenamed() {
        let first = AgentSkill(name: "duplicate", summary: "First", body: "First")
        let second = AgentSkill(name: "duplicate", summary: "Second", body: "Second")
        for selected in [first, second] {
            let library = SkillLibraryModel(skills: [first, second])
            #expect(library.renameConflictingSkill(selected.id, to: "unique"))
            #expect(library.skill(selected.id)?.name == "unique")
            #expect(library.conflictingSkillIDs.isEmpty)
        }
    }

    @Test func importedReservedNamesAreRenamedAndLiveSnapshotsStayFrozen() async throws {
        let library = SkillLibraryModel()
        let old = library.catalog
        let imported = library.install(
            .init(name: "skill-installer", description: "Custom", body: "Custom"), importedFrom: "SKILL.md")
        #expect(imported.name == "skill-installer-2")
        #expect(old.names == ["skill-creator", "skill-installer"])
        #expect(library.catalog.names.contains(imported.name))
    }

    @Test func draftTitlesCanPassThroughReservedNamesWithoutShadowingBuiltIns() {
        let library = SkillLibraryModel()
        var draft = AgentSkill(name: "", title: "Skill Creator", summary: "Custom", body: "Mine")
        library.upsert(draft)
        #expect(library.conflictingSkillIDs.contains(draft.id))
        #expect(!library.lockName(for: draft.id))
        draft.title = "Skill Creator For My Team"
        library.upsert(draft)
        #expect(library.lockName(for: draft.id))
        #expect(library.skill(draft.id)?.name == "skill-creator-for-my-team")
        library.upsert(AgentSkill(name: "skill-creator", summary: "Invalid", body: "Invalid"))
        #expect(library.storageError != nil)
        library.upsert(draft)
        #expect(library.storageError == nil)
    }

    @Test func packageCommitsAndRollbackPreserveBinaryFilesAndRevision() async throws {
        let persistence = TestSkillPersistence()
        let library = SkillLibraryModel(persistence: persistence)
        let before = library.snapshot
        let skill = AgentSkill(
            name: "example", summary: "Example", body: "Read", package: .init(files: ["image.bin": Data([0, 255])]))
        persistence.fail = true
        await #expect(throws: (any Error).self) {
            try await library.installSkill(skill, expectedRevision: before.revision)
        }
        #expect(library.snapshot.revision == before.revision)
        #expect(library.skills.isEmpty)
        persistence.fail = false
        try await library.installSkill(skill, expectedRevision: before.revision)
        #expect(persistence.values == [skill])
        await #expect(throws: (any Error).self) {
            try await library.installSkill(
                AgentSkill(name: "second", summary: "s", body: "b"), expectedRevision: before.revision)
        }
        #expect(persistence.values == [skill])
    }
}

@MainActor private final class TestSkillPersistence: SkillLibraryPersisting {
    var values: [AgentSkill] = []
    var saves = 0
    var fail = false
    func load() throws -> [AgentSkill] { values }
    func save(_ skills: [AgentSkill]) throws {
        if fail { throw CocoaError(.fileWriteNoPermission) }
        saves += 1
        values = skills
    }
}

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindPersistence
import Testing

@Suite
@MainActor
struct SkillLibraryModelTests {
    @Test
    func roundTripsThroughSwiftData() throws {
        let container = try makeContainer("SkillRoundTrip")
        let skill = AgentSkill(
            name: "disk-triage", title: "Disk Triage",
            summary: "Triage a full disk.", body: "1. Check df.",
            isEnabled: false, importedFrom: "SKILL.md",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let persistence = SkillPersistence(context: container.mainContext)
        try persistence.save([skill])

        let reloaded = try SkillPersistence(context: container.mainContext).load()
        #expect(reloaded.count == 1)
        #expect(reloaded[0].id == skill.id)
        #expect(reloaded[0].name == "disk-triage")
        #expect(reloaded[0].body == "1. Check df.")
        #expect(reloaded[0].isEnabled == false)
        #expect(reloaded[0].importedFrom == "SKILL.md")
    }

    @Test
    func aFailedSaveRollsTheLibraryBackAndSaysSo() {
        let persistence = FailingSkillPersistence()
        let library = SkillLibraryModel(persistence: persistence)
        library.upsert(AgentSkill(name: "kept", summary: "s", body: "b"))
        #expect(library.skills.count == 1)

        persistence.shouldFail = true
        library.upsert(AgentSkill(name: "lost", summary: "s", body: "b"))

        #expect(library.skills.map(\.name) == ["kept"])
        #expect(library.storageError != nil)
    }

    @Test
    func theCatalogFollowsTheEnabledSwitch() {
        let library = SkillLibraryModel()
        let skill = AgentSkill(name: "disk-triage", summary: "s", body: "b")
        library.upsert(skill)
        #expect(Set(library.catalog.names) == AgentSkillLibrary.reservedNames.union(["disk-triage"]))

        library.setEnabled(false, for: skill.id)
        #expect(library.catalog.names == AgentSkillLibrary.builtIns.map(\.name))
    }

    @Test
    func lockingANameFreezesItAgainstLaterTitleEdits() {
        let library = SkillLibraryModel()
        var skill = AgentSkill(name: "", title: "Disk Triage", summary: "s", body: "b")
        library.upsert(skill)
        #expect(library.skill(skill.id)?.effectiveName == "disk-triage")

        #expect(library.lockName(for: skill.id))
        skill = try! #require(library.skill(skill.id))
        skill.title = "Something Else"
        library.upsert(skill)
        #expect(library.skill(skill.id)?.effectiveName == "disk-triage")
    }

    @Test
    func lockingRefusesANameAnotherSkillAlreadyHas() {
        let library = SkillLibraryModel()
        library.upsert(AgentSkill(name: "disk-triage", summary: "s", body: "b"))
        let second = AgentSkill(name: "", title: "Disk Triage", summary: "s", body: "b")
        library.upsert(second)

        #expect(!library.lockName(for: second.id))
    }

    /// A second `pdf-processing` from another collection is two skills the user
    /// wants, not one they want overwritten.
    @Test
    func importingADuplicateNameNumbersItRatherThanReplacing() throws {
        let library = SkillLibraryModel()
        let document = try AgentSkillDocument.parse(
            """
            ---
            name: pdf-processing
            description: Reads PDFs.
            ---
            # PDF Processing

            Steps.
            """)
        let first = library.install(document, importedFrom: "SKILL.md")
        let second = library.install(document, importedFrom: "SKILL.md")

        #expect(first.name == "pdf-processing")
        #expect(second.name == "pdf-processing-2")
        #expect(second.title == "PDF Processing")
        #expect(library.skills.count == 2)
    }

    /// The migration an existing install actually performs. Additive and
    /// lightweight, so what it has to prove is that the store still opens and
    /// nothing that was in it was lost on the way to the new entity.
    @Test
    func aSchemaV10StoreOpensAtV11WithItsContentsIntact() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindSkillV11Migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV10.self)

        var legacy: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration("SkillMigration", schema: legacySchema, url: storeURL)
            ]
        )
        legacy?.mainContext.insert(
            PersistentMCPServer(MCPServer(name: "Gateway", namespaceID: "gateway"), sortIndex: 0)
        )
        try legacy?.mainContext.save()
        legacy = nil

        let migrated = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "SkillMigration", schema: HostPersistence.schema, url: storeURL
                )
            ]
        )
        let servers = try migrated.mainContext.fetch(FetchDescriptor<PersistentMCPServer>())
        #expect(servers.map(\.name) == ["Gateway"])

        // The new table exists and is usable, which is the whole point of V11.
        let skills = SkillPersistence(context: migrated.mainContext)
        try skills.save([AgentSkill(name: "x", summary: "s", body: "b")])
        #expect(try skills.load().map(\.name) == ["x"])
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let configuration = localModelConfiguration(
            name, schema: HostPersistence.schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
    }
}

@MainActor
private final class FailingSkillPersistence: SkillLibraryPersisting {
    var shouldFail = false
    private var stored: [AgentSkill] = []

    func load() throws -> [AgentSkill] { stored }

    func save(_ skills: [AgentSkill]) throws {
        if shouldFail { throw AgentSkillImportError.notReadable }
        stored = skills
    }
}

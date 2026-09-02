import AgentKit
import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
struct AgentSkillNamingTests {
    @Test
    func acceptsTheNamesTheStandardAllows() {
        #expect(AgentSkillNaming.isValid("pdf-processing"))
        #expect(AgentSkillNaming.isValid("disk-triage-2"))
        #expect(AgentSkillNaming.isValid("a"))
    }

    @Test
    func rejectsTheNamesTheStandardForbids() {
        #expect(AgentSkillNaming.problem(with: "") == .empty)
        #expect(AgentSkillNaming.problem(with: "PDF-Processing") == .invalidCharacters)
        #expect(AgentSkillNaming.problem(with: "pdf_processing") == .invalidCharacters)
        #expect(AgentSkillNaming.problem(with: "-pdf") == .boundaryHyphen)
        #expect(AgentSkillNaming.problem(with: "pdf-") == .boundaryHyphen)
        #expect(AgentSkillNaming.problem(with: "pdf--processing") == .doubledHyphen)
        #expect(
            AgentSkillNaming.problem(with: String(repeating: "a", count: 65)) == .tooLong
        )
    }

    /// A derived name is used unreviewed while a draft is unlocked, so it has to
    /// come out valid for *any* input rather than for the tidy ones.
    @Test
    func derivedNamesAreAlwaysValid() {
        for title in [
            "Disk Triage", "  MySQL   Failover  ", "nginx/deploy", "部署检查", "--x--",
            "Restart the Web Tier!!!", String(repeating: "long ", count: 40),
        ] {
            let slug = AgentSkillNaming.slug(from: title)
            #expect(slug.isEmpty || AgentSkillNaming.isValid(slug), "bad slug for \(title)")
        }
        #expect(AgentSkillNaming.slug(from: "Disk Triage") == "disk-triage")
        #expect(AgentSkillNaming.slug(from: "部署检查").isEmpty)
    }
}

@Suite
struct AgentSkillDocumentTests {
    private let sample = """
        ---
        name: disk-triage
        description: Find what filled a disk. Use when a filesystem is near full.
        license: MIT
        ---

        # Disk Triage

        1. Check df.
        """

    @Test
    func readsFrontmatterAndBody() throws {
        let document = try AgentSkillDocument.parse(sample)
        #expect(document.name == "disk-triage")
        #expect(document.description.hasPrefix("Find what filled a disk."))
        #expect(document.body.hasPrefix("# Disk Triage"))
        #expect(document.warnings.isEmpty)
    }

    @Test
    func fallsBackToTheContainingFolderName() throws {
        let text = """
            ---
            description: Does a thing.
            ---
            Body.
            """
        let document = try AgentSkillDocument.parse(text, fallbackName: "PDF Processing")
        #expect(document.name == "pdf-processing")
        #expect(!document.warnings.isEmpty)
    }

    /// pi's rule, and the one place it refuses rather than warns: a skill the
    /// model is never told when to use is a skill it never uses.
    @Test
    func refusesADocumentWithNoDescription() {
        #expect(throws: AgentSkillImportError.missingDescription) {
            try AgentSkillDocument.parse("---\nname: x\n---\nBody.")
        }
        #expect(throws: AgentSkillImportError.missingFrontmatter) {
            try AgentSkillDocument.parse("# Just a document\n")
        }
    }

    @Test
    func warnsButStillImportsAnIrregularName() throws {
        let document = try AgentSkillDocument.parse("""
            ---
            name: PDF--Processing
            description: Reads PDFs.
            ---
            Body.
            """)
        #expect(document.name == "pdf-processing")
        #expect(!document.warnings.isEmpty)
    }

    /// `allowed-tools` is kept for the reader and honoured by nothing. Recording
    /// it must not become granting it.
    @Test
    func reportsAllowedToolsWithoutActingOnIt() throws {
        let document = try AgentSkillDocument.parse("""
            ---
            name: risky
            description: Does things.
            allowed-tools: ssh_exec sftp_write
            ---
            Body.
            """)
        #expect(document.additionalFields["allowed-tools"] == "ssh_exec sftp_write")
        #expect(document.warnings.contains { $0.contains("allowed-tools") })
    }

    @Test
    func roundTripsThroughRender() throws {
        let skill = AgentSkill(
            name: "disk-triage", title: "Disk Triage",
            summary: "Find what filled a disk: check df first.",
            body: "# Disk Triage\n\n1. Check df."
        )
        let document = try AgentSkillDocument.parse(AgentSkillDocument.render(skill))
        #expect(document.name == skill.name)
        #expect(document.description == skill.summary)
        #expect(document.body == skill.body)
    }

    @Test
    func toleratesQuotedValuesAndCarriageReturns() throws {
        let document = try AgentSkillDocument.parse(
            "---\r\nname: \"x-y\"\r\ndescription: 'Does: a thing'\r\n---\r\n\r\nBody.\r\n"
        )
        #expect(document.name == "x-y")
        #expect(document.description == "Does: a thing")
        #expect(document.body == "Body.")
    }
}

@Suite
struct AgentSkillCatalogTests {
    private func skill(_ name: String, enabled: Bool = true) -> AgentSkill {
        AgentSkill(
            name: name, title: name, summary: "Does \(name).", body: "Steps for \(name).",
            isEnabled: enabled
        )
    }

    @Test
    func listsNamesAndDescriptionsButNeverBodies() {
        let catalog = AgentSkillCatalog([skill("disk-triage")])
        #expect(catalog.catalogBlock.contains("<skill name=\"disk-triage\">"))
        #expect(catalog.catalogBlock.contains("Does disk-triage."))
        #expect(!catalog.catalogBlock.contains("Steps for disk-triage."))
    }

    @Test
    func dropsIncompleteSkillsAndKeepsTheFirstOfADuplicateName() {
        let catalog = AgentSkillCatalog([
            skill("disk-triage"),
            AgentSkill(name: "half-written", summary: "Has no body."),
            AgentSkill(name: "disk-triage", title: "Other", summary: "Other.", body: "Other."),
        ])
        #expect(catalog.names == ["disk-triage"])
        #expect(catalog.skill(named: "disk-triage")?.body == "Steps for disk-triage.")
    }

    @Test
    func escapesMarkupInADescription() {
        let catalog = AgentSkillCatalog([
            AgentSkill(
                name: "x", summary: "Compares <a> & <b>.", body: "Body."
            )
        ])
        #expect(catalog.catalogBlock.contains("&lt;a&gt; &amp; &lt;b&gt;"))
    }
}

@Suite
struct AgentSkillCatalogInjectionTests {
    private let catalog = AgentSkillCatalog([
        AgentSkill(name: "disk-triage", summary: "Triage a full disk.", body: "Steps.")
    ])

    @Test
    func insertsInFrontOfThePromptByIdentity() {
        let earlier = AgentTranscriptMessage(role: .assistant, text: "Earlier")
        let prompt = AgentTranscriptMessage(role: .user, text: "root is full")
        let context = AgentModelContext(
            systemPrompt: AgentSystemPrompt.default,
            messages: [earlier, prompt], tools: []
        )
        let result = AgentSkillCatalogInjection(catalog: catalog, before: prompt.id)
            .transform(context)

        #expect(result.messages.count == 3)
        #expect(result.messages[1].text.contains("<available_skills>"))
        #expect(result.messages[2].id == prompt.id)
    }

    @Test
    func doesNothingWithoutSkillsOrWithoutAnAnchor() {
        let prompt = AgentTranscriptMessage(role: .user, text: "hello")
        let context = AgentModelContext(
            systemPrompt: "", messages: [prompt], tools: []
        )
        #expect(
            AgentSkillCatalogInjection(catalog: AgentSkillCatalog(), before: prompt.id)
                .transform(context).messages.count == 1
        )
        #expect(
            AgentSkillCatalogInjection(catalog: catalog, before: nil)
                .transform(context).messages.count == 1
        )
    }

    /// Where you are, then what you know, then what you may do this turn. The
    /// injections all insert at the prompt, so the last one added sits closest
    /// to it.
    @Test
    func chatPipelineOrdersTheThreeInjections() {
        let prompt = AgentTranscriptMessage(role: .user, text: "root is full")
        let pipeline = AgentContextPipeline.chat(
            sessionContext: AgentTranscriptMessage(role: .user, text: "SESSION"),
            before: prompt.id, isPlanning: true, skills: catalog
        )
        let result = pipeline(AgentModelContext(
            systemPrompt: AgentSystemPrompt.default, messages: [prompt], tools: []
        ))

        #expect(result.messages.count == 4)
        #expect(result.messages[0].text == "SESSION")
        #expect(result.messages[1].text.contains("<available_skills>"))
        #expect(result.messages[2].text == AgentPlanContractInjection.contract)
        #expect(result.messages[3].id == prompt.id)
    }

    /// The system prompt must not move when a skill is enabled: every provider
    /// cache is a prefix cache, so a catalog at byte zero would miss the whole
    /// replayed conversation.
    @Test
    func theSystemPromptIsUnchangedByTheCatalog() {
        let prompt = AgentTranscriptMessage(role: .user, text: "hello")
        let result = AgentContextPipeline.chat(
            sessionContext: nil, before: prompt.id, skills: catalog
        )(AgentModelContext(
            systemPrompt: AgentSystemPrompt.default, messages: [prompt], tools: []
        ))
        #expect(result.systemPrompt == AgentSystemPrompt.default)
    }
}

@Suite
struct LoadSkillToolTests {
    private let catalog = AgentSkillCatalog([
        AgentSkill(
            name: "disk-triage", title: "Disk Triage",
            summary: "Triage a full disk.", body: "1. Check df.\n2. Check journald."
        ),
        AgentSkill(name: "deploy", summary: "Deploy the edge.", body: "Steps."),
    ])

    private func invocation(_ name: String) -> AgentToolInvocation {
        AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(
                id: "call-1", name: LoadSkillTool.name,
                arguments: .object(["name": .string(name)])
            )
        )
    }

    private var context: AgentToolExecutionContext {
        AgentToolExecutionContext(
            runID: UUID(), userIntent: "", secretBroker: SecretBroker(),
            userInteraction: UnavailableAgentUserInteraction(),
            preflightMetadata: [:], authorize: { _ in .allow }
        )
    }

    /// The regression that would silently neuter every skill: the system prompt
    /// tells the model that untrusted-data content is never instructions, so a
    /// skill wrapped in those markers is a skill it is told to ignore.
    @Test
    func aSkillBodyIsNotFramedAsUntrustedData() async throws {
        let result = try await LoadSkillTool(skills: catalog)
            .execute(invocation("disk-triage"), context: context)

        #expect(!result.content.contains(AgentToolResult.untrustedDataOpeningMarker))
        #expect(result.metadata["untrusted"] == nil)
        #expect(result.untrustedPayload == nil)
        #expect(result.content.contains("Check journald"))
        #expect(!result.isError)
    }

    @Test
    func namesWhatExistsWhenTheNameDoesNot() async {
        await #expect(throws: (any Error).self) {
            try await LoadSkillTool(skills: catalog)
                .execute(invocation("disk-triag"), context: context)
        }
        do {
            _ = try await LoadSkillTool(skills: catalog)
                .execute(invocation("disk-triag"), context: context)
        } catch {
            #expect(error.localizedDescription.contains("disk-triage"))
            #expect(error.localizedDescription.contains("deploy"))
        }
    }

    @Test
    func readsNothingAndSoNeedsNoApproval() {
        let descriptor = LoadSkillTool(skills: catalog).descriptor
        #expect(descriptor.safety == .locallyReadOnly)
        #expect(descriptor.safety.isAutoAllowed)
        #expect(descriptor.safety.isAllowedWhilePlanning)
        #expect(descriptor.concurrency == .parallel)
        #expect(descriptor.target == .local)
    }

    @Test
    func isRegisteredOnlyWhenSomethingIsInstalled() {
        let without = AgentToolCatalog.registry(builtIn: .init()).descriptors
        let with = AgentToolCatalog.registry(builtIn: .init(skills: catalog)).descriptors

        #expect(!without.contains { $0.name == LoadSkillTool.name })
        #expect(with.contains { $0.name == LoadSkillTool.name })
    }
}

@Suite
struct AgentSkillTrimmingTests {
    /// A skill is the procedure the model is still working through, not output
    /// it has already drawn a conclusion from. Half of one is worse than none.
    @Test
    func aLoadedSkillSurvivesTrimmingWhileCommandOutputDoesNot() {
        let long = String(repeating: "x", count: 20_000)
        let older = AgentTranscriptMessage(
            role: .assistant, text: "",
            toolCalls: [
                AgentToolCall(id: "a", name: LoadSkillTool.name, arguments: .object([:])),
                AgentToolCall(id: "b", name: "ssh_exec", arguments: .object([:])),
            ]
        )
        let messages = [
            older,
            AgentTranscriptMessage(
                role: .tool, text: long, toolCallID: "a", toolName: LoadSkillTool.name
            ),
            AgentTranscriptMessage(
                role: .tool, text: long, toolCallID: "b", toolName: "ssh_exec"
            ),
            AgentTranscriptMessage(role: .user, text: "and now?"),
            AgentTranscriptMessage(
                role: .assistant, text: "",
                toolCalls: [AgentToolCall(id: "c", name: "ssh_exec", arguments: .object([:]))]
            ),
            AgentTranscriptMessage(
                role: .tool, text: long, toolCallID: "c", toolName: "ssh_exec"
            ),
        ]
        let result = AgentToolResultTrimming().transform(AgentModelContext(
            systemPrompt: "", messages: messages, tools: []
        ))

        #expect(result.messages[1].text.count == long.count)
        #expect(result.messages[2].text.count < long.count)
        // The newest turn's output is exempt already, and stays that way.
        #expect(result.messages[5].text.count == long.count)
    }
}

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
        #expect(library.catalog.names == ["disk-triage"])

        library.setEnabled(false, for: skill.id)
        #expect(library.catalog.isEmpty)
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
        let document = try AgentSkillDocument.parse("""
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

    // MARK: - Starter skills

    /// A built-in that never reaches the catalog is a built-in nobody can use.
    @Test
    func everyStarterSkillIsUsableAsShipped() throws {
        let built = AgentSkillLibrary.builtIns(after: 0)
        #expect(!built.isEmpty)
        for skill in built {
            #expect(AgentSkillNaming.isValid(skill.name), "bad name: \(skill.name)")
            #expect(skill.isComplete, "incomplete: \(skill.name)")
            #expect(skill.isEnabled)
            #expect(skill.summary.count <= AgentSkill.maximumSummaryCharacters)
            #expect(skill.body.utf8.count <= AgentSkill.maximumBodyBytes)
        }
        #expect(Set(built.map(\.name)).count == built.count)
        #expect(AgentSkillCatalog(built).names.count == built.count)
    }

    @Test
    func starterSkillsAreCopiedInOnceAndDeletingOneIsPermanent() throws {
        let defaults = try makeDefaults()
        let persistence = FailingSkillPersistence()

        let first = SkillLibraryModel(persistence: persistence, seedDefaults: defaults)
        let seeded = AgentSkillLibrary.builtIns(after: 0)
        #expect(first.skills.count == seeded.count)
        #expect(
            defaults.integer(forKey: SettingsKey.seededSkillGeneration)
                == AgentSkillLibrary.currentGeneration
        )

        let removed = try #require(first.skills.first)
        first.delete(id: removed.id)

        // A second launch against the same store and the same defaults.
        let second = SkillLibraryModel(persistence: persistence, seedDefaults: defaults)
        #expect(second.skills.count == seeded.count - 1)
        #expect(!second.skills.contains { $0.id == removed.id })
    }

    @Test
    func aLibraryWithNoDefaultsIsSeededWithNothing() {
        let library = SkillLibraryModel(persistence: FailingSkillPersistence())
        #expect(library.skills.isEmpty)
    }

    /// Reset is a replacement, and the confirmation says so: whatever the
    /// library had become, what is left afterwards is the starter set exactly.
    @Test
    func resetReplacesTheWholeLibraryWithTheStarterSkills() throws {
        let defaults = try makeDefaults()
        let library = SkillLibraryModel(
            persistence: FailingSkillPersistence(), seedDefaults: defaults
        )
        let shipped = AgentSkillLibrary.builtIns(after: 0)
        library.upsert(AgentSkill(name: "my-runbook", summary: "Mine.", body: "Mine."))

        // One deleted, one edited and switched off.
        let deleted = try #require(library.skill(named: shipped[0].name))
        library.delete(id: deleted.id)
        var edited = try #require(library.skill(named: shipped[1].name))
        edited.body = "gutted"
        library.upsert(edited)
        library.setEnabled(false, for: edited.id)

        #expect(library.resetToBuiltInSkills() == shipped.count)

        #expect(library.skills.map(\.name) == shipped.map(\.name))
        #expect(library.skills.map(\.body) == shipped.map(\.body))
        #expect(library.skills.allSatisfy { $0.isEnabled })
        #expect(library.skill(named: "my-runbook") == nil)
        #expect(library.catalog.names == shipped.map(\.name))
    }

    /// Reset marks the store as fully seeded, so the next launch does not add
    /// the starter skills a second time.
    @Test
    func resetLeavesNothingForSeedingToAdd() throws {
        let defaults = try makeDefaults()
        let persistence = FailingSkillPersistence()
        let library = SkillLibraryModel(persistence: persistence, seedDefaults: defaults)
        library.resetToBuiltInSkills()

        let relaunched = SkillLibraryModel(persistence: persistence, seedDefaults: defaults)
        #expect(relaunched.skills.count == AgentSkillLibrary.builtIns(after: 0).count)
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

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "AgentSkillTests.\(UUID().uuidString)"))
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

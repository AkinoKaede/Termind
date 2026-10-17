import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import Testing

@Suite @MainActor
struct AISettingsIntegrationTests {
    @Test func rolesResolveOnlyEnabledChatModelsAndFallBackToChat() {
        var provider = ModelProvider(name: "Enabled")
        provider.models = [AIModel(id: "chat"), AIModel(id: "embedding", kind: .embedding)]
        let ai = AIConfigurationModel(modelProviders: [provider])
        #expect(ai.resolve(.chat)?.model.id == "chat")
        #expect(ai.resolve(.commandGenerator)?.model.id == "chat")
        #expect(ai.resolve(.guardian)?.model.id == "chat")
        ai.setModelProviderEnabled(false, for: provider.id)
        #expect(ai.resolve(.chat) == nil)
    }

    @Test func guardianAutomaticPrioritySelectsTheHighestModelInEachFamily() {
        let provider = ModelProvider(
            name: "Models",
            models: [
                AIModel(id: "OPENAI-CODEX/CODEX-AUTO-REVIEW"),
                AIModel(id: "gpt-5.6-luna"), AIModel(id: "GPT-6.1-LUNA"),
                AIModel(id: "claude-sonnet-5"), AIModel(id: "claude-sonnet-4-6"),
                AIModel(id: "gemini-3.8-flash"), AIModel(id: "other"),
            ]
        )
        let codex = AIModelRef(modelProviderID: provider.id, modelID: "OPENAI-CODEX/CODEX-AUTO-REVIEW")
        let newestLuna = AIModelRef(modelProviderID: provider.id, modelID: "GPT-6.1-LUNA")

        let codexChat = AIConfigurationModel(modelProviders: [provider], roles: [.chat: codex])
        #expect(codexChat.resolve(.guardian)?.model.id == "OPENAI-CODEX/CODEX-AUTO-REVIEW")

        let lunaChat = AIConfigurationModel(modelProviders: [provider], roles: [.chat: newestLuna])
        #expect(lunaChat.resolve(.guardian)?.model.id == "OPENAI-CODEX/CODEX-AUTO-REVIEW")

        let explicit = AIConfigurationModel(
            modelProviders: [provider], roles: [.chat: newestLuna, .guardian: newestLuna]
        )
        #expect(explicit.resolve(.guardian)?.model.id == "GPT-6.1-LUNA")

        let fallbackProvider = ModelProvider(name: "Fallback", models: [AIModel(id: "other")])
        let fallback = AIConfigurationModel(modelProviders: [fallbackProvider])
        #expect(fallback.resolve(.guardian)?.model.id == "other")

        let additionalFamilies = ModelProvider(
            name: "Additional",
            models: [
                AIModel(id: "deepseek-v4-flash"), AIModel(id: "DEEPSEEK-V5.2-FLASH"),
                AIModel(id: "glm-6-flash"),
            ]
        )
        let deepSeekChat = AIModelRef(
            modelProviderID: additionalFamilies.id, modelID: "DEEPSEEK-V5.2-FLASH"
        )
        let additional = AIConfigurationModel(
            modelProviders: [additionalFamilies], roles: [.chat: deepSeekChat]
        )
        #expect(additional.resolve(.guardian)?.model.id == "DEEPSEEK-V5.2-FLASH")

        let semanticVersions = ModelProvider(
            name: "Semantic",
            models: [AIModel(id: "chat"), AIModel(id: "gpt-0.8-luna"), AIModel(id: "gpt-0.11-luna")]
        )
        let semantic = AIConfigurationModel(modelProviders: [semanticVersions])
        #expect(semantic.resolve(.guardian)?.model.id == "gpt-0.11-luna")

        let glmVersions = ModelProvider(
            name: "GLM",
            models: [AIModel(id: "chat"), AIModel(id: "glm-4-flash"), AIModel(id: "GLM-4.7-FLASH")]
        )
        let glm = AIConfigurationModel(modelProviders: [glmVersions])
        #expect(glm.resolve(.guardian)?.model.id == "GLM-4.7-FLASH")
    }

    @Test func skillImportExportPreservesContentAndSupportingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let skill = AgentSkill(
            name: "disk-check", title: "Disk", summary: "Inspect disks.", body: "# Disk\nRead usage.")
        try Data(AgentSkillDocument.render(skill).utf8).write(to: directory.appending(path: "SKILL.md"))
        try Data("unused".utf8).write(to: directory.appending(path: "reference.txt"))
        let outcome = try SkillImporter.read(directory)
        #expect(outcome.document.name == skill.name)
        #expect(outcome.document.description == skill.summary)
        #expect(outcome.document.body.contains("Read usage."))
        #expect(outcome.warnings.isEmpty)
        #expect(outcome.document.package.files["reference.txt"] == Data("unused".utf8))
        let library = SkillLibraryModel()
        let first = library.install(outcome.document, importedFrom: outcome.origin)
        let second = library.install(outcome.document, importedFrom: outcome.origin)
        #expect(first.name == "disk-check")
        #expect(second.name == "disk-check-2")
    }

    @Test func importerRejectsOversizedAndNonUTF8Files() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).md")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 65, count: AgentSkill.maximumBodyBytes + 1).write(to: file)
        #expect(throws: (any Error).self) { try SkillImporter.read(file) }
        try Data([0xff, 0xfe, 0xff]).write(to: file)
        #expect(throws: (any Error).self) { try SkillImporter.read(file) }
    }

    @Test func syncedLibraryKeepsBuiltInsOutOfPersistenceAndPreservesOtherSettings() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "AISettingsIntegrationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try persistence.prepare()
        let library = SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(persistence))
        #expect(library.skills.isEmpty)
        #expect(library.catalog.names == ["skill-creator", "skill-installer", "ssh-exec"])
        try persistence.prepare()
        #expect(try persistence.load().skills.isEmpty)
        let ai = AIConfigurationModel(persistence: SyncedAIConfigurationPersistence(persistence))
        let server = MCPServer(name: "Preserved")
        ai.upsert(server)
        let custom = AgentSkill(name: "custom", summary: "s", body: "b")
        library.upsert(custom)
        #expect(try persistence.load().configuration.mcpServers == [server])
        #expect(try persistence.load().skills.contains { $0.id == custom.id })
        #expect(library.skills.map(\.id) == [custom.id])
        #expect(
            try persistence.journal.pendingEnvelopes().allSatisfy {
                guard case .skill(let skill, _) = $0.payload else { return true }
                return !AgentSkillLibrary.reservedNames.contains(skill.name)
            })
    }

    @Test func failedProviderTransactionKeepsModelsAndAssignmentsTogether() {
        let persistence = FailingAISettings()
        var provider = ModelProvider(name: "Test")
        provider.models = [AIModel(id: "one")]
        let ref = AIModelRef(modelProviderID: provider.id, modelID: "one")
        persistence.snapshot = .init(providers: [provider], roles: [.chat: ref])
        let ai = AIConfigurationModel(persistence: persistence)
        provider.models = []
        #expect(!ai.saveProvider(provider, endpoint: ProviderEndpoint(url: "https://example.invalid/v1")))
        #expect(ai.modelProvider(provider.id)?.models.map(\.id) == ["one"])
        #expect(ai.roles[.chat] == ref)
    }
}

@MainActor private final class FailingAISettings: AIConfigurationPersisting {
    var snapshot = AIConfigurationSnapshot(providers: [], roles: [:])
    func load() throws -> AIConfigurationSnapshot { snapshot }
    func save(_ value: AIConfigurationSnapshot) throws { throw CocoaError(.fileWriteNoPermission) }
}

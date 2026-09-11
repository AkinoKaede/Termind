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
        #expect(ai.resolve(.securityReview)?.model.id == "chat")
        ai.setModelProviderEnabled(false, for: provider.id)
        #expect(ai.resolve(.chat) == nil)
    }

    @Test func skillImportExportPreservesContentAndReportsOmittedFiles() throws {
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
        #expect(outcome.warnings.count == 1)
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

    @Test func syncedLibrarySeedsOnceAndPreservesOtherSettings() throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let domain = "AISettingsIntegrationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let persistence = SettingsSyncPersistence(context: container.mainContext, defaults: defaults)
        try persistence.prepare()
        let library = SkillLibraryModel(persistence: SyncedSkillLibraryPersistence(persistence))
        let initial = library.skills
        #expect(!initial.isEmpty)
        library.delete(id: initial[0].id)
        try persistence.prepare()
        #expect(try persistence.load().skills.allSatisfy { $0.id != initial[0].id })
        let ai = AIConfigurationModel(persistence: SyncedAIConfigurationPersistence(persistence))
        let server = MCPServer(name: "Preserved")
        ai.upsert(server)
        let custom = AgentSkill(name: "custom", summary: "s", body: "b")
        library.upsert(custom)
        #expect(try persistence.load().configuration.mcpServers == [server])
        #expect(try persistence.load().skills.contains { $0.id == custom.id })
        library.resetToBuiltInSkills()
        #expect(!library.skills.contains { $0.id == custom.id })
        #expect(library.skills.count == AgentSkillLibrary.builtIns(after: 0).count)
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

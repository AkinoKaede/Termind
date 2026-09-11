import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindRemoteInfrastructure
import Testing

@testable import TermindIOS

@Suite @MainActor
struct MobileAssistantTests {
    @Test func changingConversationsPreservesTheirDraftsAndArchiveNavigation() async throws {
        let app = try MobileAppModel(inMemory: true)
        let model = app.assistant
        let first = ConversationModel(messages: [ChatMessage(role: .user, text: "First")])
        let second = ConversationModel(messages: [ChatMessage(role: .user, text: "Second")])
        model.library.insertAndSelect(first)
        first.composer.draft = "first draft"
        model.library.insertAndSelect(second)
        second.composer.draft = "second draft"
        model.select(first)
        #expect(model.conversation.composer.draft == "first draft")
        model.select(second)
        #expect(model.conversation.composer.draft == "second draft")
        #expect(first.composer.draft == "first draft")
    }

    @Test func slashCatalogCarriesNamesAndDescriptionsIntoTheMobilePanel() throws {
        let app = try MobileAppModel(inMemory: true)
        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Inspect")])
        app.assistant.library.insertAndSelect(conversation)
        let composer = MobileAssistantComposer(pro: app.pro, model: app.assistant, conversation: conversation)
        let compact = try #require(composer.availableCommands.first { $0.id == "compact" })
        #expect(compact.name == "/compact")
        #expect(compact.summary == String(localized: "Summarize older turns to free context"))
        #expect(!compact.summary.isEmpty)
    }

    @Test func completeRegistryIncludesRemoteAndBuiltInToolsOnlyForCapableModels() throws {
        let app = try MobileAppModel(inMemory: true)
        let hosts = AgentHostResolver(store: app.library)
        let connections = AgentConnectionPool(
            configuration: { _ in throw CancellationError() },
            routeFingerprint: { _ in "" }, openExec: { _ in throw CancellationError() },
            openSFTP: { _ in throw CancellationError() }, sweepInterval: nil)
        let authentication = AgentSSHAuthenticationRegistry(resolver: hosts)
        let background = AgentBackgroundCommands(sweepInterval: nil)
        let repository = InMemoryAgentRunRepository()
        let channel = AgentEventChannel(repository: repository)
        var model = AIModel(id: "test")
        model.abilities = [.toolCall]
        let provider = ModelProvider(name: "Test")
        let conversation = ConversationModel()
        func registry(_ model: AIModel) -> AgentToolRegistry {
            AssistantToolRegistry.make(
                conversation: conversation, model: model, provider: provider,
                skills: app.skills.catalog, channel: channel, ai: app.ai, hosts: hosts, metrics: app.metrics.core,
                connections: connections, authentication: authentication, background: background)
        }
        let names = Set(registry(model).descriptors.map(\.name))
        for name in [
            "ssh_exec", "ssh_wait", "sftp_read", "sftp_write", "list_hosts", "get_metrics",
            "scratch_pull", "scratch_push", "present_plan", "manage_tasks", "request_user_input", "request_user_secret",
        ] {
            #expect(names.contains(name), "Missing tool: \(name)")
        }
        #expect(!names.contains("terminal_suggest"))
        model.abilities = []
        #expect(registry(model).descriptors.isEmpty)
    }

    @Test func backgroundExpirationBlocksNewRunsUntilCleanupCompletes() async throws {
        let app = try MobileAppModel(inMemory: true)
        app.assistant.conversation.composer.draft = "preserve"
        app.assistant.expireBackground()
        #expect(app.assistant.isSuspending)
        app.assistant.send()
        #expect(app.assistant.conversation.composer.draft == "preserve")
        await app.assistant.waitForSuspension()
        #expect(!app.assistant.isSuspending)
        #expect(!app.assistant.isRunning)
    }
}

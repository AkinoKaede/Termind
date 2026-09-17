import AgentKit
import Foundation
import TermindApplication
import Testing

/// Opt-in real-network smoke test against a disposable compatible model server.
/// TERMIND_MODEL_HTTP_TEST_URLS is a comma-separated list of base URLs. The server
/// answers ordinary prompts with OK and honors the title/command JSON contracts.
@Suite @MainActor
struct ProviderHTTPIntegrationTests {
    @Test func nativeAppCanUseAnonymousHTTPEndpoints() async throws {
        guard let urls = ProcessInfo.processInfo.environment["TERMIND_MODEL_HTTP_TEST_URLS"] else { return }
        for base in urls.split(separator: ",").map(String.init) {
            let provider = ModelProvider(
                name: "Anonymous HTTP", inferenceURL: base + "/chat/completions", baseURL: base,
                models: [AIModel(id: "test")])
            let ai = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
            let secret = try #require(ai.modelSecret(for: provider))
            #expect(secret.isEmpty)
            let models = try await ModelCatalogClient().models(for: provider, secret: secret)
            #expect(models.map(\.id) == ["test"])
            let probe = try await ChatProbe().run(model: provider.models[0], on: provider, secret: secret)
            #expect(probe.reply == "OK")
            let command = CommandGeneratorController(ai: ai)
            #expect(command.isLocallyAvailable)
            #expect(try await command.generate(.init(draft: "say OK", shell: "zsh", cwd: "/tmp")) == "echo OK")
            let title = try await ConversationTitleController(ai: ai).summarize(
                .init(firstUserMessage: "Say OK", firstAssistantMessage: "OK"))
            #expect(title == "Local model")
        }
    }
}

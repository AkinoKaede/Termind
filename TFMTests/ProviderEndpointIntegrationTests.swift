import AgentKit
import SwiftData
import TermindApplication
import TermindDomain
import TermindPersistence
import TermindRemoteInfrastructure
import Testing

@testable import Termind

@Suite @MainActor
struct ProviderEndpointIntegrationTests {
    @Test func anonymousHTTPProviderSurvivesPersistenceReload() throws {
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
        let provider = ModelProvider(name: "Local", models: [AIModel(id: "local-model")])
        let store = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
        #expect(store.saveProvider(provider, endpoint: ProviderEndpoint(url: "http://localhost:11434/v1")))
        let reloaded = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
        let saved = try #require(reloaded.modelProvider(provider.id))
        #expect(saved.credentialRef.isEmpty)
        #expect(saved.inferenceURL == "http://localhost:11434/v1/chat/completions")
        #expect(saved.models.map(\.id) == ["local-model"])
        #expect(saved.canFetchModels)
        #expect(reloaded.modelSecret(for: saved) == "")
        #expect(CommandGeneratorController(ai: reloaded).isLocallyAvailable)
    }

    /// The round trip the editor depends on: what was typed comes back, and so
    /// does the difference between `Automatic` and picking the same format.
    @Test
    func endpointsSurviveAReloadIncludingTheAutomaticChoice() throws {
        let container = try ModelContainer(
            for: HostPersistence.schema,
            configurations: [
                ModelConfiguration(
                    "EndpointRoundTrip", schema: HostPersistence.schema,
                    isStoredInMemoryOnly: true, cloudKitDatabase: .none
                )
            ]
        )

        let automatic = ModelProvider(name: "Automatic")
        let explicit = ModelProvider(name: "Explicit")

        do {
            let store = AIConfigurationModel(
                modelContext: container.mainContext, persistsSecrets: false
            )
            store.upsert(automatic)
            store.upsert(explicit)
            store.setEndpoint(ProviderEndpoint(url: "https://x.test/v1"), for: automatic.id)
            store.setEndpoint(
                ProviderEndpoint(apiType: .messages, url: "https://x.test/v1"), for: explicit.id
            )
            #expect(store.storageError == nil)
        }

        let reloaded = AIConfigurationModel(
            modelContext: container.mainContext, persistsSecrets: false
        )
        #expect(reloaded.endpoint(for: automatic.id).apiType == .automatic)
        #expect(reloaded.endpoint(for: automatic.id).url == "https://x.test/v1")
        #expect(reloaded.modelProvider(automatic.id)?.apiFormat == .chatCompletions)
        #expect(
            reloaded.modelProvider(automatic.id)?.inferenceURL == "https://x.test/v1/chat/completions"
        )

        #expect(reloaded.endpoint(for: explicit.id).apiType == .messages)
        #expect(reloaded.endpoint(for: explicit.id).url == "https://x.test/v1")
        #expect(reloaded.modelProvider(explicit.id)?.inferenceURL == "https://x.test/v1/messages")
    }
}

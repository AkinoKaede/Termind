import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct AIProviderPersistenceTests {
    @Test
    func providerConfigurationRoundTripsThroughSwiftData() throws {
        let container = try makeContainer("AIProviderRoundTrip")
        var model = reasoningModel("gpt-5.6-sol")
        model.displayName = "GPT 5.6 Sol"
        model.ownedBy = "openai"
        model.input = [.text, .image]
        model.contextLength = 272_000
        model.maxOutputTokens = 128_000
        model.origin = .fetched
        model.reasoningProfile = ReasoningProfile(levels: [
            .off: ReasoningLevelMapping(isSupported: true, wireValue: "none"),
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "maximum"),
        ])
        let provider = ModelProvider(
            name: "Work OpenAI",
            kind: .openAI,
            isEnabled: false,
            baseURL: "https://gateway.example/v1",
            apiPath: "/responses",
            credentialRef: "termind.ai.key.reference-only",
            usesResponsesAPI: true,
            usesVertex: false,
            vertex: VertexConfig(
                projectID: "remembered-project",
                location: "us-central1",
                credentialRef: "termind.ai.vertex.reference-only",
                clientEmail: "agent@example.iam.gserviceaccount.com"
            ),
            models: [model],
            modelsFetchedAt: Date(timeIntervalSince1970: 1234)
        )
        let ref = AIModelRef(modelProviderID: provider.id, modelID: model.id)

        do {
            let store = AIStore(modelContext: container.mainContext, persistsSecrets: false)
            store.upsert(provider)
            store.assign(ref, to: .chat)
            store.select(ref)
            #expect(store.storageError == nil)
        }

        let reloaded = AIStore(modelContext: container.mainContext, persistsSecrets: false)
        #expect(reloaded.modelProviders == [provider])
        #expect(reloaded.roles == [.chat: ref])
        #expect(reloaded.lastSelectedModel == ref)
        #expect(reloaded.storageError == nil)
        #expect(
            try container.mainContext.fetch(FetchDescriptor<PersistentModelProvider>())
                .first?.credentialRef == "termind.ai.key.reference-only"
        )
    }

    @Test
    func deletionCleansPersistedReferences() throws {
        let container = try makeContainer("AIProviderDeletion")
        let model = reasoningModel("gpt-5.4")
        let provider = ModelProvider(name: "OpenAI", models: [model])
        let ref = AIModelRef(modelProviderID: provider.id, modelID: model.id)
        let store = AIStore(modelContext: container.mainContext, persistsSecrets: false)
        store.upsert(provider)
        store.assign(ref, to: .chat)
        store.select(ref)

        store.removeModels([model.id], from: provider.id)

        let reloaded = AIStore(modelContext: container.mainContext, persistsSecrets: false)
        #expect(reloaded.modelProvider(provider.id)?.models.isEmpty == true)
        #expect(reloaded.roles.isEmpty)
        #expect(reloaded.lastSelectedModel == nil)
    }

    @Test
    func catalogReplacementKeepsManualReasoningOverride() {
        var original = reasoningModel("custom-reasoner")
        original.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "strong")
        ])
        let provider = ModelProvider(name: "Gateway", models: [original])
        let store = AIStore(modelProviders: [provider], persistsSecrets: false)

        store.replaceModels([reasoningModel(original.id)], for: provider.id)

        #expect(
            store.modelProvider(provider.id)?.model(original.id)?.reasoningProfile
                == original.reasoningProfile
        )
    }

    @Test
    func versionFourStoreMigratesWithEmptyAIConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TermindAIMigration-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: "Termind.store")
        let host = Host(name: "Existing Host", host: "existing.example")

        do {
            let schema = Schema(versionedSchema: TermindSchemaV4.self)
            let configuration = ModelConfiguration("Migration", schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            container.mainContext.insert(PersistentHost(host))
            try container.mainContext.save()
        }

        let schema = Schema(versionedSchema: TermindSchemaV5.self)
        let configuration = ModelConfiguration("Migration", schema: schema, url: storeURL)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [configuration]
        )

        #expect(
            try container.mainContext.fetch(FetchDescriptor<PersistentHost>()).map(\.value)
                == [host]
        )
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentModelProvider>()).isEmpty)
        #expect(try container.mainContext.fetch(FetchDescriptor<PersistentAIModel>()).isEmpty)
    }

    private func makeContainer(_ name: String) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            name, schema: HostPersistence.schema, isStoredInMemoryOnly: true
        )
        return try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [configuration]
        )
    }
}

@Suite
struct ModelCapabilityResolverTests {
    @Test
    func bundledPiCatalogEnrichesKnownModelWithoutRegex() {
        let provider = ModelProvider(name: "OpenAI")
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "gpt-5.4"),
            provider: provider
        )

        #expect(ModelCapabilityResolver.catalogMetadata?.version == "0.84.3")
        #expect(ModelCapabilityResolver.catalogMetadata?.modelCount == 1_312)
        #expect(resolution.catalogSource == .init(provider: "openai", modelID: "gpt-5.4"))
        #expect(resolution.model.input == [.text, .image])
        #expect(resolution.model.abilities == [.toolCall, .reasoning])
        #expect(resolution.model.contextLength == 272_000)
        #expect(resolution.model.maxOutputTokens == 128_000)
        #expect(resolution.supported == [.off, .low, .medium, .high, .xHigh])
    }

    @Test
    func explicitlyReportedFieldsWinOverPiCatalog() {
        let provider = ModelProvider(name: "OpenAI")
        var model = AIModel(id: "gpt-5.4")
        model.kind = .other
        model.input = [.audio]
        model.output = [.image]
        model.abilities = []
        model.contextLength = 7
        model.maxOutputTokens = 8

        let resolution = ModelCapabilityResolver.resolve(
            model: model,
            provider: provider,
            reported: [.kind, .input, .output, .abilities]
        )

        #expect(resolution.model.kind == .other)
        #expect(resolution.model.input == [.audio])
        #expect(resolution.model.output == [.image])
        #expect(resolution.model.abilities.isEmpty)
        #expect(resolution.model.contextLength == 7)
        #expect(resolution.model.maxOutputTokens == 8)
        #expect(resolution.supported == [.off])
    }

    @Test
    func editorCapabilityOverrideIsAuthoritativeDuringEffortResolution() {
        let provider = ModelProvider(name: "OpenAI")
        let model = AIModel(id: "gpt-5.4")

        let reasoning = ModelCapabilityResolver.reasoning(model: model, provider: provider)

        #expect(reasoning.supported == [.off])
    }

    @Test
    func nonReasoningModelsOnlySupportOff() {
        let provider = ModelProvider(name: "OpenAI")
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "gpt-4o"), provider: provider
        )

        #expect(resolution.supported == [.off])
        #expect(resolution.clamp(.max) == .off)
    }

    @Test
    func openAIExtendedFamiliesFollowPiStyleExceptions() {
        let provider = ModelProvider(name: "OpenAI")
        let gpt54 = ModelCapabilityResolver.resolve(
            model: reasoningModel("gpt-5.4"), provider: provider
        )
        let gpt56 = ModelCapabilityResolver.resolve(
            model: reasoningModel("gpt-5.6-sol"), provider: provider
        )
        let pro = ModelCapabilityResolver.resolve(
            model: reasoningModel("gpt-5-pro"), provider: provider
        )

        #expect(gpt54.supported == [.off, .low, .medium, .high, .xHigh])
        #expect(gpt54.wireValue(for: .off) == "none")
        #expect(gpt56.supported.last == .max)
        #expect(pro.supported == [.high])
    }

    @Test
    func providerNamespacesAndGoogleWireValuesAreResolved() {
        let openRouter = ModelProvider(
            name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"
        )
        let claude = ModelCapabilityResolver.resolve(
            model: reasoningModel("anthropic/claude-opus-4.7"), provider: openRouter
        )
        let google = ModelProvider(name: "Google", kind: .google)
        let gemini = ModelCapabilityResolver.resolve(
            model: reasoningModel("gemini-3.1-pro-preview"), provider: google
        )

        #expect(
            claude.catalogSource
                == .init(provider: "openrouter", modelID: "anthropic/claude-opus-4.7")
        )
        #expect(Array(claude.supported.suffix(2)) == [.xHigh, .max])
        #expect(gemini.supported == [.low, .high])
        #expect(gemini.wireValue(for: .low) == "LOW")
        #expect(gemini.clamp(.medium) == .high)
    }

    @Test
    func manualProfileOverridesAutomaticRulesAndClampPrefersUpward() {
        let provider = ModelProvider(name: "Gateway")
        var model = reasoningModel("unknown-reasoner")
        model.reasoningProfile = ReasoningProfile(levels: [
            .off: ReasoningLevelMapping(isSupported: true),
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "strong"),
        ])
        let resolution = ModelCapabilityResolver.resolve(model: model, provider: provider)

        #expect(resolution.catalogSource == nil)
        #expect(resolution.supported == [.off, .high])
        #expect(resolution.clamp(.low) == .high)
        #expect(resolution.clamp(.max) == .high)
        #expect(resolution.wireValue(for: .high) == "strong")
    }

    @Test
    func blankCustomWireValueUsesTheProviderDefault() {
        let google = ModelProvider(name: "Google", kind: .google)
        var model = reasoningModel("gemini-3.1-pro-preview")
        model.reasoningProfile = ReasoningProfile(levels: [
            .low: ReasoningLevelMapping(isSupported: true, wireValue: nil),
            .max: ReasoningLevelMapping(isSupported: true, wireValue: nil),
        ])

        let resolution = ModelCapabilityResolver.resolve(model: model, provider: google)

        #expect(resolution.wireValue(for: .low) == "LOW")
        #expect(resolution.wireValue(for: .max) == "MAX")
    }
}

private func reasoningModel(_ id: String) -> AIModel {
    var model = AIModel(id: id)
    model.abilities.insert(.reasoning)
    return model
}

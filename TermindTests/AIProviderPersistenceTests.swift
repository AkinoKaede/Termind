import Foundation
import SwiftData
import Testing

@testable import Termind

@Suite
@MainActor
struct AIProviderPersistenceTests {
    @Test
    func mcpConfigurationRoundTripsThroughSwiftData() throws {
        let container = try makeContainer("MCPRoundTrip")
        let connectedAt = Date(timeIntervalSince1970: 5_678)
        let header = MCPHeader(name: "X-Tenant", value: "acme")
        let tool = MCPTool(
            id: "search-records",
            title: "Search records",
            summary: "Search the tenant database",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")])
                ]),
            ]),
            annotations: MCPToolAnnotations(
                title: "Search", readOnlyHint: true, destructiveHint: false,
                idempotentHint: true, openWorldHint: false
            ),
            accessPolicy: .followPermissions
        )
        let server = MCPServer(
            name: "Work Gateway",
            namespaceID: "work_gateway",
            transport: .sse,
            url: "https://mcp.example/sse",
            isEnabled: false,
            credentialRef: "termind.ai.mcp.reference-only",
            headers: [header],
            tools: [tool],
            negotiatedVersion: "2025-06-18",
            lastConnectedAt: connectedAt
        )

        do {
            let store = AIConfigurationModel(
                modelContext: container.mainContext, persistsSecrets: false
            )
            store.upsert(server)
            #expect(store.storageError == nil)
        }

        let reloaded = AIConfigurationModel(
            modelContext: container.mainContext, persistsSecrets: false
        )
        #expect(reloaded.mcpServers == [server])
        #expect(reloaded.availableTools.isEmpty)
        #expect(reloaded.mcpStatus(of: server.id) == .disconnected)
        #expect(
            try container.mainContext.fetch(FetchDescriptor<PersistentMCPServer>())
                .first?.credentialRef == "termind.ai.mcp.reference-only"
        )
    }

    @Test
    func mcpRediscoveryKeepsPoliciesAndPersistsNewToolsSafely() throws {
        let container = try makeContainer("MCPRediscovery")
        var server = MCPServer(name: "Gateway")
        server.tools = [
            MCPTool(id: "existing", accessPolicy: .followPermissions)
        ]
        let store = AIConfigurationModel(
            modelContext: container.mainContext, persistsSecrets: false
        )
        store.upsert(server)

        store.setTools(
            [MCPTool(id: "existing"), MCPTool(id: "new")],
            version: "2025-06-18",
            for: server.id
        )

        let reloaded = AIConfigurationModel(
            modelContext: container.mainContext, persistsSecrets: false
        )
        let tools = try #require(reloaded.mcpServer(server.id)?.tools)
        #expect(tools.first { $0.id == "existing" }?.accessPolicy == .followPermissions)
        #expect(tools.first { $0.id == "new" }?.accessPolicy == .alwaysAsk)
        #expect(reloaded.mcpServer(server.id)?.negotiatedVersion == "2025-06-18")
        #expect(reloaded.mcpServer(server.id)?.lastConnectedAt != nil)
    }

    @Test
    func deletingMCPServerRemovesPersistenceAndCredential() throws {
        let container = try makeContainer("MCPDeletion")
        let secrets = InMemorySecretStore()
        let credentialRef = "termind.ai.mcp.delete-me"
        let removed = MCPServer(
            name: "Removed", credentialRef: credentialRef
        )
        let kept = MCPServer(name: "Kept")
        let store = AIConfigurationModel(
            modelContext: container.mainContext,
            secrets: secrets
        )
        store.setSecret("secret", for: credentialRef)
        store.upsert(removed)
        store.upsert(kept)

        store.delete(serverID: removed.id)

        let reloaded = AIConfigurationModel(
            modelContext: container.mainContext,
            secrets: secrets
        )
        #expect(reloaded.mcpServers == [kept])
        #expect(try secrets.string(for: credentialRef, storage: .thisDevice) == nil)
    }

    @Test
    func mcpSaveFailureRollsBackMemoryState() {
        let server = MCPServer(name: "Gateway")
        let persistence = FailingAIConfigurationPersistence(
            snapshot: AIConfigurationSnapshot(
                providers: [], roles: [:], lastSelectedModel: nil,
                mcpServers: [server]
            )
        )
        let store = AIConfigurationModel(
            persistence: persistence, persistsSecrets: false
        )
        persistence.shouldFail = true

        store.setServerEnabled(false, for: server.id)

        #expect(store.mcpServer(server.id)?.isEnabled == true)
        #expect(store.storageError != nil)
    }

    @Test
    func corruptMCPNestedDataFallsBackWithoutDroppingServer() throws {
        let container = try makeContainer("MCPCorruptNestedData")
        let row = PersistentMCPServer(MCPServer(name: "Gateway"), sortIndex: 0)
        row.headersData = Data("not-json".utf8)
        row.toolsData = Data("not-json".utf8)
        container.mainContext.insert(row)
        try container.mainContext.save()

        let reloaded = AIConfigurationModel(
            modelContext: container.mainContext, persistsSecrets: false
        )

        #expect(reloaded.mcpServers.count == 1)
        #expect(reloaded.mcpServers.first?.name == "Gateway")
        #expect(reloaded.mcpServers.first?.headers.isEmpty == true)
        #expect(reloaded.mcpServers.first?.tools.isEmpty == true)
    }

    @Test
    func schemaV1MigratesToV2WithExistingDataAndNoMCPServers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindSchemaMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Termind.store")
        let legacySchema = Schema(versionedSchema: TermindSchemaV1.self)
        let provider = ModelProvider(name: "Existing Provider")

        var legacyContainer: ModelContainer? = try ModelContainer(
            for: legacySchema,
            configurations: [
                localModelConfiguration(
                    "Migration", schema: legacySchema, url: storeURL
                )
            ]
        )
        legacyContainer?.mainContext.insert(PersistentModelProvider(provider, sortIndex: 0))
        try legacyContainer?.mainContext.save()
        legacyContainer = nil

        let migratedContainer = try ModelContainer(
            for: HostPersistence.schema,
            migrationPlan: TermindMigrationPlan.self,
            configurations: [
                localModelConfiguration(
                    "Migration", schema: HostPersistence.schema, url: storeURL
                )
            ]
        )
        let migratedProviders = try migratedContainer.mainContext.fetch(
            FetchDescriptor<PersistentModelProvider>()
        )
        let migratedMCPServers = try migratedContainer.mainContext.fetch(
            FetchDescriptor<PersistentMCPServer>()
        )

        #expect(migratedProviders.map(\.name) == ["Existing Provider"])
        #expect(migratedMCPServers.isEmpty)
    }

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
        model.isShownInAssistant = false
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
            let store = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
            store.upsert(provider)
            store.assign(ref, to: .chat)
            store.select(ref)
            #expect(store.storageError == nil)
        }

        let reloaded = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
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
        let store = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
        store.upsert(provider)
        store.assign(ref, to: .chat)
        store.assign(ref, to: .commandGenerator)
        store.select(ref)

        store.removeModels([model.id], from: provider.id)

        let reloaded = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
        #expect(reloaded.modelProvider(provider.id)?.models.isEmpty == true)
        #expect(reloaded.roles.isEmpty)
        #expect(reloaded.lastSelectedModel == nil)
    }

    @Test
    func commandGeneratorAssignmentPersistsIndependentlyAndFallsBackToChat() throws {
        let container = try makeContainer("CommandGeneratorRole")
        let chatModel = reasoningModel("chat-model")
        let generatorModel = reasoningModel("generator-model")
        let provider = ModelProvider(name: "OpenAI", models: [chatModel, generatorModel])
        let chatRef = AIModelRef(modelProviderID: provider.id, modelID: chatModel.id)
        let generatorRef = AIModelRef(modelProviderID: provider.id, modelID: generatorModel.id)

        do {
            let store = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
            store.upsert(provider)
            store.assign(chatRef, to: .chat)
            #expect(store.resolve(.commandGenerator)?.model.id == chatModel.id)
            store.assign(generatorRef, to: .commandGenerator)
            #expect(store.resolve(.commandGenerator)?.model.id == generatorModel.id)
        }

        let reloaded = AIConfigurationModel(modelContext: container.mainContext, persistsSecrets: false)
        #expect(reloaded.assignment(for: .chat) == chatRef)
        #expect(reloaded.assignment(for: .commandGenerator) == generatorRef)
        #expect(AIRole.allCases == [.chat, .commandGenerator, .securityReview])
        #expect(AIRole.commandGenerator.unsetLabel == "Same as Chat")
    }


    @Test
    func catalogReplacementKeepsManualModelOverrides() {
        var original = reasoningModel("custom-reasoner")
        original.isShownInAssistant = false
        original.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true, wireValue: "strong")
        ])
        let provider = ModelProvider(name: "Gateway", models: [original])
        let store = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)

        store.replaceModels([reasoningModel(original.id)], for: provider.id)

        #expect(
            store.modelProvider(provider.id)?.model(original.id)?.reasoningProfile
                == original.reasoningProfile
        )
        #expect(
            store.modelProvider(provider.id)?.model(original.id)?.isShownInAssistant == false
        )
    }

    @Test
    func hiddenAssistantModelRemainsAvailableToSettingsAndResolution() {
        var hidden = reasoningModel("review-only")
        hidden.isShownInAssistant = false
        let visible = reasoningModel("chat")
        let provider = ModelProvider(name: "OpenAI", models: [hidden, visible])
        let hiddenRef = AIModelRef(modelProviderID: provider.id, modelID: hidden.id)
        let store = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)

        #expect(provider.chatModels.map(\.id) == [hidden.id, visible.id])
        #expect(provider.assistantModels.map(\.id) == [visible.id])

        store.assign(hiddenRef, to: .securityReview)
        store.select(hiddenRef)
        #expect(store.assignment(for: .securityReview) == hiddenRef)
        #expect(store.resolve(.securityReview)?.model.id == hidden.id)
        #expect(store.resolve(conversation: nil)?.model.id == hidden.id)
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
private final class FailingAIConfigurationPersistence: AIConfigurationPersisting {
    let snapshot: AIConfigurationSnapshot
    var shouldFail = false

    init(snapshot: AIConfigurationSnapshot) {
        self.snapshot = snapshot
    }

    func load() throws -> AIConfigurationSnapshot { snapshot }

    func save(_ snapshot: AIConfigurationSnapshot) throws {
        if shouldFail { throw TestPersistenceError.failed }
    }
}

private enum TestPersistenceError: Error {
    case failed
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
        // `webSearch` is the one ability that does come from the model id, and
        // it has to: Pi's catalog has no field for server-side search, so this
        // record says nothing about it either way. The rule the rest of this
        // test guards is unchanged — a record that *does* list abilities is
        // taken verbatim, and only a record silent on them is filled in.
        #expect(resolution.model.abilities == [.toolCall, .reasoning, .webSearch])
        #expect(resolution.model.contextLength == 272_000)
        #expect(resolution.model.maxOutputTokens == 128_000)
        #expect(resolution.model.isShownInAssistant)
        #expect(resolution.supported == [.off, .low, .medium, .high, .xHigh])
    }

    /// Nobody publishes server-side search as a capability: no `/models`
    /// payload carries it and Pi's catalog has no field for it. So "the
    /// endpoint reported its abilities" must not be read as "the endpoint said
    /// there is no search" — otherwise the ability stays off for exactly the
    /// well-described models most likely to have it.
    @Test
    func webSearchIsInferredEvenWhenTheEndpointReportedItsAbilities() {
        let provider = ModelProvider(name: "OpenAI")
        var reportedModel = AIModel(id: "gpt-5.4")
        reportedModel.abilities = [.toolCall]

        let resolution = ModelCapabilityResolver.resolve(
            model: reportedModel, provider: provider, reported: [.abilities]
        )

        // The reported list is still honoured — reasoning is absent because the
        // endpoint did not claim it — and search is added on top.
        #expect(resolution.model.abilities == [.toolCall, .webSearch])
    }

    /// DeepSeek v4 reaches `/responses` with the identical
    /// `{"type": "web_search"}` OpenAI uses, so it needs recognising rather than
    /// any code of its own.
    @Test
    func deepSeekV4IsRecognisedAsSearchCapable() {
        var provider = ModelProvider(name: "DeepSeek")
        provider.baseURL = "https://api.deepseek.com/v1"
        provider.usesResponsesAPI = true

        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "deepseek-v4-pro"), provider: provider
        )
        #expect(resolution.model.abilities.contains(.webSearch))
        #expect(provider.supportsNativeWebSearch(model: resolution.model))

        // The older chat-completions models are excluded by the provider gate
        // even where the id might tempt the pattern.
        var legacy = ModelProvider(name: "DeepSeek Chat")
        legacy.baseURL = "https://api.deepseek.com/v1"
        #expect(!legacy.supportsNativeWebSearch(model: resolution.model))
    }

    /// The failure this pins reads `Unknown tool: web_search` at runtime.
    ///
    /// An OpenAI-shaped `/responses` gateway pointed at Claude accepts
    /// `{"type": "web_search"}` and forwards it as an ordinary function
    /// declaration. The model then calls `web_search` as a tool — and native
    /// mode deliberately withholds the local one, so nothing can run it.
    /// A server tool only exists where the vendor's API and the vendor's model
    /// meet.
    @Test
    func nativeSearchNeedsTheModelFamilyToMatchTheEndpoint() {
        var claude = AIModel(id: "anthropic/claude-sonnet-4")
        claude.abilities = [.toolCall, .webSearch]

        var gateway = ModelProvider(name: "OpenRouter")
        gateway.baseURL = "https://openrouter.ai/api/v1"
        gateway.usesResponsesAPI = true
        #expect(!gateway.supportsNativeWebSearch(model: claude))

        // The same model on Anthropic's own API does have it.
        var anthropic = ModelProvider(name: "Anthropic")
        anthropic.kind = .anthropic
        #expect(anthropic.supportsNativeWebSearch(model: claude))

        // And a Gemini id on an Anthropic-shaped endpoint is the same mistake
        // in the other direction.
        var gemini = AIModel(id: "gemini-2.5-pro")
        gemini.abilities = [.toolCall, .webSearch]
        #expect(!anthropic.supportsNativeWebSearch(model: gemini))

        var google = ModelProvider(name: "Google")
        google.kind = .google
        #expect(google.supportsNativeWebSearch(model: gemini))
    }

    /// DeepSeek ships both shapes and implements the server tool in each, so
    /// the family rule has to be about implementation rather than branding.
    /// Reading "not Anthropic's own model" as "no native search" would refuse a
    /// pairing that works.
    @Test
    func deepSeekIsAFirstPartyOnBothShapes() {
        var model = AIModel(id: "deepseek-v4-pro")
        model.abilities = [.toolCall, .webSearch]

        // https://api.deepseek.com/anthropic — `server_tool_use` and
        // `web_search_tool_result` are documented as supported there.
        var anthropicShaped = ModelProvider(name: "DeepSeek via Anthropic")
        anthropicShaped.kind = .anthropic
        anthropicShaped.baseURL = "https://api.deepseek.com/anthropic"
        #expect(anthropicShaped.supportsNativeWebSearch(model: model))

        // https://api.deepseek.com/v1/responses — `{"type": "web_search"}`.
        var responsesShaped = ModelProvider(name: "DeepSeek via Responses")
        responsesShaped.baseURL = "https://api.deepseek.com/v1"
        responsesShaped.usesResponsesAPI = true
        #expect(responsesShaped.supportsNativeWebSearch(model: model))

        // Chat Completions has no search on any shape, and the older models
        // never get the ability in the first place.
        var chat = ModelProvider(name: "DeepSeek Chat")
        chat.baseURL = "https://api.deepseek.com/v1"
        #expect(!chat.supportsNativeWebSearch(model: model))

        var legacyModel = AIModel(id: "deepseek-chat")
        legacyModel.abilities = ModelCapabilityResolver.resolve(
            model: AIModel(id: "deepseek-chat"), provider: responsesShaped
        ).model.abilities
        #expect(!legacyModel.abilities.contains(.webSearch))
    }

    @Test
    func searchIsNotInferredForModelsThatCannotChat() {
        let provider = ModelProvider(name: "OpenAI")
        for id in ["text-embedding-3-large", "dall-e-3"] {
            let resolution = ModelCapabilityResolver.resolve(
                model: AIModel(id: id), provider: provider
            )
            #expect(!resolution.model.abilities.contains(.webSearch), "\(id)")
        }
    }

    @Test
    func bundledOverrideEnrichesCodexAutoReview() {
        let provider = ModelProvider(name: "OpenAI")
        let resolution = ModelCapabilityResolver.resolve(
            model: AIModel(id: "codex-auto-review"),
            provider: provider
        )

        #expect(resolution.catalogSource == .init(provider: "openai", modelID: "codex-auto-review"))
        #expect(resolution.model.ownedBy == "openai")
        #expect(resolution.model.input == [.text, .image])
        #expect(resolution.model.output == [.text])
        #expect(resolution.model.abilities == [.toolCall, .reasoning])
        #expect(resolution.model.contextLength == 272_000)
        #expect(resolution.model.maxOutputTokens == nil)
        #expect(!resolution.model.isShownInAssistant)
        #expect(resolution.supported == [.low, .medium, .high, .xHigh, .max])
        #expect(resolution.wireValue(for: .xHigh) == "xhigh")
        #expect(resolution.wireValue(for: .max) == "max")
        #expect(resolution.clamp(.off) == .low)
        #expect(resolution.clamp(.minimal) == .low)
    }

    @Test
    func reportedFieldsWinOverCodexAutoReviewOverride() {
        let provider = ModelProvider(name: "OpenAI")
        var model = AIModel(id: "codex-auto-review")
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
        // Reported abilities still win — `toolCall` and `reasoning` stay off
        // despite the catalog claiming both for gpt-5.4. `webSearch` is the
        // exception, deliberately: an empty array is the endpoint listing what
        // it knows about, and no endpoint knows about server-side search. See
        // `webSearchIsInferredEvenWhenTheEndpointReportedItsAbilities`.
        #expect(resolution.model.abilities == [.webSearch])
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
        // Upward is the safe direction for a job that must reason, and the wrong
        // one for a job that need not: asking for low here buys full effort. A
        // caller that wants the cheapest level asks for off, which is the only
        // request this clamp cannot answer by walking up — see
        // `ConversationTitleController`.
        #expect(resolution.clamp(.off) == .off)
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

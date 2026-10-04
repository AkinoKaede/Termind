import AgentKit
import Foundation
import Testing

@Suite
struct PiModelCatalogTests {
    @Test
    func bundledImageAndClassifierRecordsRemainOutsideAssistantPickers() {
        var provider = ModelProvider(name: "OpenRouter")
        provider.baseURL = "https://openrouter.ai/api/v1"
        let image = ModelCapabilityResolver.resolve(
            model: AIModel(id: "black-forest-labs/flux-3-image"), provider: provider
        )
        let classifier = ModelCapabilityResolver.resolve(
            model: AIModel(id: "typesafe/jev-1.13"), provider: provider
        )
        #expect(image.catalogSource?.provider == "openrouter")
        #expect(image.model.kind == .imageGeneration)
        #expect(image.model.output == [.image])
        #expect(image.model.abilities.isEmpty)
        #expect(classifier.catalogSource?.provider == "openrouter")
        #expect(classifier.model.kind == .classifier)
        #expect(classifier.model.abilities.isEmpty)
        provider.models = [image.model, classifier.model]
        #expect(provider.assistantModels.isEmpty)
    }

    @Test
    func sharedIDsPreferChatAndOverridesStillHideInternalModels() {
        var provider = ModelProvider(name: "OpenRouter")
        provider.baseURL = "https://openrouter.ai/api/v1"
        let router = ModelCapabilityResolver.resolve(model: AIModel(id: "openrouter/auto"), provider: provider)
        #expect(router.catalogSource?.provider == "openrouter")
        #expect(router.model.kind == .chat)
        #expect(router.model.abilities.contains(.toolCall))

        provider.baseURL = "https://api.openai.com/v1"
        let review = ModelCapabilityResolver.resolve(model: AIModel(id: "codex-auto-review"), provider: provider)
        #expect(review.catalogSource?.provider == "openai")
        #expect(review.model.isShownInAssistant == false)
        #expect(review.model.abilities.contains(.reasoning))
    }
}

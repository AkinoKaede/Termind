import AgentKit
import Foundation

/// Resolves `.chat`, deliberately, rather than introducing a Titler role.
///
/// `AIRole` argues the case: a role earns its place by wanting a *materially
/// different* model, and titling wants "whatever the chat model is, but
/// cheaper" — which the Chat picker already expresses. Cheapness comes from
/// clamping the reasoning budget instead, the same way Command Generator does.
@MainActor
public final class ConversationTitleController: ConversationTitling {
    private let ai: AIConfigurationModel
    private let service: ConversationTitleService

    public init(ai: AIConfigurationModel, service: ConversationTitleService = ConversationTitleService()) {
        self.ai = ai
        self.service = service
    }

    public func summarize(_ context: ConversationTitleContext) async throws -> String {
        guard let resolved = ai.resolve(.chat) else {
            throw ConversationTitleError.missingModel
        }
        guard let secret = ai.modelSecret(for: resolved.provider) else {
            throw ConversationTitleError.missingCredential
        }
        // `.off`, not `.low`. The shared clamp walks *upward* first, which is
        // right for Guardian — a review that does not reason is worse
        // than a slow one — but backwards here. Asking for low on a model whose
        // levels are `[off, high]`, as several Kimi builds are, hands back high:
        // full reasoning effort to write six words. Asking for off takes off
        // where it exists and the lowest available level where it does not.
        let reasoning = ModelCapabilityResolver.reasoning(
            model: resolved.model, provider: resolved.provider
        ).clamp(.off)
        let model = AgentProviderClient(
            provider: resolved.provider, model: resolved.model, secret: secret,
            reasoning: reasoning
        )
        return try await service.summarize(context: context, model: model)
    }
}

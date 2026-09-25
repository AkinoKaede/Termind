import AgentKit
import Foundation

/// Device-local model choices for durable conversations. Drafts remain in memory.
@MainActor
public protocol AssistantModelSelectionStoring {
    func load() throws -> [UUID: AIModelRef]
    func save(_ model: AIModelRef, for conversationID: UUID) throws
}

@MainActor
public final class InMemoryAssistantModelSelectionStore: AssistantModelSelectionStoring {
    private var selections: [UUID: AIModelRef] = [:]

    public init() {}

    public func load() throws -> [UUID: AIModelRef] { selections }

    public func save(_ model: AIModelRef, for conversationID: UUID) throws {
        selections[conversationID] = model
    }
}

/// Freezes new chats and repairs an unavailable choice exactly once.
@MainActor
public final class AssistantModelSelectionController {
    private let ai: AIConfigurationModel
    private let store: any AssistantModelSelectionStoring

    public init(ai: AIConfigurationModel, store: any AssistantModelSelectionStoring) {
        self.ai = ai
        self.store = store
    }

    public func seed(_ conversation: ConversationModel) {
        guard conversation.model == nil else { return }
        conversation.model = defaultModel
    }

    /// Restore and backfill before publishing historical conversations.
    public func selectionsForRestore(_ conversations: [StoredAgentConversation]) throws -> [UUID: AIModelRef] {
        let saved = try store.load()
        var selected: [UUID: AIModelRef] = [:]
        for conversation in conversations {
            let old = saved[conversation.id]
            let model = old.flatMap { ai.lookupChat($0) == nil ? nil : $0 } ?? defaultModel
            guard let model else { continue }
            if model != old { try store.save(model, for: conversation.id) }
            selected[conversation.id] = model
        }
        return selected
    }

    /// Called before a turn is captured, including the first turn of a draft.
    @discardableResult
    public func prepareForSend(_ conversation: ConversationModel) throws -> AIModelRef? {
        let model = conversation.model.flatMap { ai.lookupChat($0) == nil ? nil : $0 } ?? defaultModel
        guard let model else { return nil }
        try store.save(model, for: conversation.id)
        conversation.model = model
        return model
    }

    public func select(_ model: AIModelRef, for conversation: ConversationModel) throws {
        guard ai.lookupChat(model) != nil else { return }
        if !conversation.transcript.isEmpty {
            try store.save(model, for: conversation.id)
        }
        conversation.model = model
        ai.select(model)
    }

    /// Existing chats keep valid choices. A provider deletion or remote settings
    /// update replaces only choices that no longer resolve.
    public func repairUnavailable(in conversations: [ConversationModel]) throws {
        for conversation in conversations {
            guard let current = conversation.model, ai.lookupChat(current) == nil,
                let replacement = defaultModel
            else { continue }
            try store.save(replacement, for: conversation.id)
            conversation.model = replacement
        }
    }

    public func persistFork(_ conversation: ConversationModel) throws {
        guard let model = conversation.model else { return }
        try store.save(model, for: conversation.id)
    }

    private var defaultModel: AIModelRef? {
        guard let resolved = ai.resolve(.chat) else { return nil }
        return AIModelRef(modelProviderID: resolved.provider.id, modelID: resolved.model.id)
    }
}

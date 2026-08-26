import Foundation

/// The app's conversations, and the single instance of each.
///
/// Conversations are app state, not window state: a run belongs to a
/// conversation, and a conversation opened in two windows is one conversation.
/// Building a `ConversationModel` per window meant a reply streaming in one
/// window was invisible in the other, and two windows could start concurrent
/// runs against the same stored history.
@Observable
final class AssistantConversationStore {
    private(set) var conversations: [ConversationModel] = []

    init(conversations: [ConversationModel] = []) {
        self.conversations = conversations
    }

    func conversation(id: ConversationModel.ID) -> ConversationModel? {
        conversations.first { $0.id == id }
    }

    func insert(_ conversation: ConversationModel) {
        guard !conversations.contains(where: { $0.id == conversation.id }) else { return }
        conversations.insert(conversation, at: 0)
    }

    /// Removes one conversation and hands back where it was, so each window can
    /// move its own selection to whatever took its place.
    @discardableResult
    func remove(_ id: ConversationModel.ID) -> Int? {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[index].stop()
        conversations.remove(at: index)
        return index
    }

    func restore(_ stored: [StoredAgentConversation]) {
        guard conversations.isEmpty else { return }
        conversations = stored.map { value in
            let conversation = ConversationModel(
                id: value.id,
                messages: value.messages.compactMap { message in
                    switch message.role {
                    case .user:
                        ChatMessage(
                            id: message.id, role: .user,
                            text: ContextChip.visiblePrompt(in: message.text),
                            contextChips: ContextChip.visibleReferences(
                                in: message.text, images: message.images
                            ),
                            images: message.images,
                            createdAt: message.createdAt
                        )
                    case .assistant:
                        ChatMessage(
                            id: message.id, role: .assistant, text: message.text,
                            createdAt: message.createdAt
                        )
                    case .tool: nil
                    }
                },
                // Tool rows are dropped from the visible list because they are
                // drawn as cards, but the model still needs them next turn.
                transcript: value.messages,
                runState: value.lastRunState
            )
            // Empty is "never summarized", not a name of nothing — `derivedTitle`
            // has to be able to tell those apart to fall back.
            conversation.title = value.title.isEmpty ? nil : value.title
            conversation.toolCards = value.toolCards.map { card in
                let state: AgentToolCard.State
                if card.result?.isInterrupted == true { state = .interrupted }
                else if card.result?.isError == true { state = .failed }
                else if card.result != nil || card.state == "finished" { state = .completed }
                // Not `.running`, which is what this used to restore to. Every
                // unfinished run is marked interrupted at launch, so a card
                // that was mid-flight when the process died is not running
                // now and never will be — it came back as a spinner that
                // nothing would ever stop.
                else if card.state == "started" { state = .interrupted }
                else { state = .proposed }
                return AgentToolCard(
                    invocation: card.invocation, descriptor: card.descriptor,
                    state: state, result: card.result, review: card.review
                )
            }
            return conversation
        }
    }
}

/// Window-local navigation over the app's conversations.
///
/// The list is shared; only the selection is per window, which is what lets two
/// windows show different chats from the same set without duplicating any of
/// them.
@Observable
final class AssistantLibraryModel {
    private var store: AssistantConversationStore
    var selectedConversationID: ConversationModel.ID?
    /// Window-local scratch space for the Assistant tab's New Chat surface.
    /// It is promoted into the shared history only after its first real send,
    /// so merely entering Assistant never creates an empty list row.
    private(set) var draftConversation = ConversationModel()

    init(store: AssistantConversationStore = AssistantConversationStore()) {
        self.store = store
        selectedConversationID = nil
    }

    var conversations: [ConversationModel] { store.conversations }

    /// Joins the app-wide store, carrying over anything this window made before
    /// it was registered. Windows are registered on appear, so in practice that
    /// is nothing — but silently dropping a conversation would be worse than the
    /// two lines it costs to keep it.
    func adopt(_ shared: AssistantConversationStore) {
        guard store !== shared else { return }
        for conversation in store.conversations.reversed() { shared.insert(conversation) }
        store = shared
        if let selectedConversationID,
            shared.conversation(id: selectedConversationID) == nil
        {
            self.selectedConversationID = nil
        }
    }

    var selectedConversation: ConversationModel? {
        guard let selectedConversationID else { return nil }
        return conversation(id: selectedConversationID)
    }

    func conversation(id: ConversationModel.ID) -> ConversationModel? {
        store.conversation(id: id)
    }

    @discardableResult
    func createConversation() -> ConversationModel {
        let conversation = ConversationModel()
        store.insert(conversation)
        selectedConversationID = conversation.id
        return conversation
    }

    /// Shows New Chat without manufacturing an empty history item. Keeping one
    /// scratch model also preserves an unfinished draft while the user briefly
    /// opens an older conversation and comes back.
    @discardableResult
    func selectNewConversation() -> ConversationModel {
        selectedConversationID = nil
        return draftConversation
    }

    /// Promotes the New Chat scratch model on its first send, then prepares a
    /// fresh scratch model for the next visit to New Chat.
    @discardableResult
    func startDraftConversation() -> ConversationModel? {
        let conversation = draftConversation
        guard let started = startConversation(conversation) else { return nil }
        draftConversation = ConversationModel()
        return started
    }

    /// Promotes the sidebar's scratch conversation into history on its first
    /// real send. Empty drafts remain ephemeral and never create blank rows.
    @discardableResult
    func startConversation(_ conversation: ConversationModel) -> ConversationModel? {
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !conversations.contains(where: { $0.id == conversation.id }) else { return nil }

        conversation.sendDraft()
        store.insert(conversation)
        selectedConversationID = conversation.id
        return conversation
    }

    func select(_ id: ConversationModel.ID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
    }

    func delete(_ id: ConversationModel.ID) {
        // `remove` returns nil when another window already took it out of the
        // shared store; this window still has a stale selection to repair.
        let index = store.remove(id)
        guard selectedConversationID == id else { return }
        let successor = index ?? 0
        selectedConversationID =
            store.conversations.indices.contains(successor)
            ? store.conversations[successor].id
            : store.conversations.first?.id
    }

    func restore(_ stored: [StoredAgentConversation]) {
        store.restore(stored)
        if let selectedConversationID,
            conversation(id: selectedConversationID) == nil
        {
            self.selectedConversationID = nil
        }
    }
}

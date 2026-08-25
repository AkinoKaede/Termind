import Foundation

/// Window-local navigation state for the fixed Assistant tab.
///
/// Conversations are no longer panes inside SSH/SFTP Workspaces. The model is
/// deliberately a separate feature boundary so persistence can later move to a
/// conversation repository without teaching WindowModel about message storage.
@Observable
final class AssistantLibraryModel {
    private(set) var conversations: [ConversationModel]
    var selectedConversationID: ConversationModel.ID?

    init(conversations: [ConversationModel] = []) {
        self.conversations = conversations
        selectedConversationID = conversations.first?.id
    }

    var selectedConversation: ConversationModel? {
        guard let selectedConversationID else { return nil }
        return conversation(id: selectedConversationID)
    }

    func conversation(id: ConversationModel.ID) -> ConversationModel? {
        conversations.first { $0.id == id }
    }

    @discardableResult
    func createConversation() -> ConversationModel {
        let conversation = ConversationModel()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        return conversation
    }

    /// Promotes the sidebar's scratch conversation into history on its first
    /// real send. Empty drafts remain ephemeral and never create blank rows.
    @discardableResult
    func startConversation(_ conversation: ConversationModel) -> ConversationModel? {
        let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard !conversations.contains(where: { $0.id == conversation.id }) else { return nil }

        conversation.sendDraft()
        conversations.insert(conversation, at: 0)
        selectedConversationID = conversation.id
        return conversation
    }

    func select(_ id: ConversationModel.ID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
    }

    func delete(_ id: ConversationModel.ID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].stop()
        conversations.remove(at: index)
        guard selectedConversationID == id else { return }
        selectedConversationID =
            conversations.indices.contains(index)
            ? conversations[index].id
            : conversations.first?.id
    }

    func restore(_ stored: [StoredAgentConversation]) {
        guard conversations.isEmpty else { return }
        conversations = stored.map { value in
            let conversation = ConversationModel(
                id: value.id,
                messages: value.messages.compactMap { message in
                    switch message.role {
                    case .user: ChatMessage(id: message.id, role: .user, text: message.text)
                    case .assistant: ChatMessage(id: message.id, role: .assistant, text: message.text)
                    case .tool: nil
                    }
                },
                runState: value.lastRunState
            )
            conversation.toolCards = value.toolCards.map { card in
                let state: AgentToolCard.State
                if card.result?.isError == true { state = .failed }
                else if card.result != nil || card.state == "finished" { state = .completed }
                else if card.state == "started" { state = .running }
                else { state = .proposed }
                return AgentToolCard(
                    invocation: card.invocation, descriptor: card.descriptor,
                    state: state, result: card.result, review: card.review
                )
            }
            return conversation
        }
        selectedConversationID = conversations.first?.id
    }
}

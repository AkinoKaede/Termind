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
        conversations.remove(at: index)
        guard selectedConversationID == id else { return }
        selectedConversationID =
            conversations.indices.contains(index)
            ? conversations[index].id
            : conversations.first?.id
    }
}

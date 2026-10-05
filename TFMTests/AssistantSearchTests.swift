import AgentKit
import Foundation
import TermindApplication
import Testing

@Suite
@MainActor
struct AssistantSearchTests {
    private func library(_ conversations: [ConversationModel]) -> AssistantLibraryModel {
        let store = AssistantConversationStore()
        for conversation in conversations.reversed() { store.insert(conversation) }
        return AssistantLibraryModel(store: store)
    }

    private func conversation(
        title: String? = nil,
        messages: [ChatMessage] = [],
        archived: Bool = false
    ) -> ConversationModel {
        let conversation = ConversationModel(messages: messages)
        conversation.customTitle = title
        if archived { conversation.archivedAt = .distantPast }
        return conversation
    }

    @Test
    func matchesTitlesAndVisibleMessageBodies() {
        let byTitle = conversation(title: "Nginx rollout")
        let byUserMessage = conversation(
            title: "Untitled",
            messages: [ChatMessage(role: .user, text: "why is nginx returning 502")]
        )
        let byAssistantMessage = conversation(
            title: "Untitled too",
            messages: [ChatMessage(role: .assistant, text: "Check the nginx upstream block.")]
        )
        let unrelated = conversation(title: "Postgres vacuum")
        let library = library([byTitle, byUserMessage, byAssistantMessage, unrelated])

        let matches = library.search("nginx", scope: .active)

        #expect(matches.count == 3)
        #expect(!matches.contains { $0 === unrelated })
    }

    @Test
    func searchIsCaseInsensitive() {
        let library = library([conversation(title: "Nginx rollout")])

        #expect(library.search("NGINX", scope: .active).count == 1)
        #expect(library.search("nGiNx", scope: .active).count == 1)
    }

    /// Active and archived are separate destinations. A match surfacing across
    /// the boundary would open a chat the user never navigated to.
    @Test
    func activeAndArchivedScopesStaySeparate() {
        let live = conversation(title: "Nginx rollout")
        let archived = conversation(title: "Nginx rollback", archived: true)
        let library = library([live, archived])

        let active = library.search("nginx", scope: .active)
        #expect(active.count == 1)
        #expect(active.first === live)

        let inArchive = library.search("nginx", scope: .archived)
        #expect(inArchive.count == 1)
        #expect(inArchive.first === archived)
    }

    /// Hidden reasoning and raw tool output are not on screen, and a search
    /// field is not a way to read them.
    @Test
    func hiddenReasoningAndToolOutputAreNotSearchable() {
        let conversation = conversation(
            title: "Deploy",
            messages: [
                ChatMessage(
                    role: .assistant,
                    text: "Done.",
                    reasoning: [AgentReasoningBlock(text: "the passphrase is hunter2")]
                )
            ]
        )
        let library = library([conversation])

        #expect(library.search("hunter2", scope: .active).isEmpty)
        #expect(library.search("Done", scope: .active).count == 1)
    }

    /// An empty query is not a filter — it is the unfiltered list, in its normal
    /// pinned-then-chats order.
    @Test
    func anEmptyQueryReturnsEverythingInScope() {
        let pinned = conversation(title: "Pinned one")
        pinned.isPinned = true
        let plain = conversation(title: "Plain one")
        let library = library([plain, pinned])

        let all = library.search("   ", scope: .active)

        #expect(all.count == 2)
        #expect(all.first === pinned)
    }
}

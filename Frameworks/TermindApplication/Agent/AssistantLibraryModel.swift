import AgentKit
import Foundation

/// The app's conversations, and the single instance of each.
///
/// Conversations are app state, not window state: a run belongs to a
/// conversation, and a conversation opened in two windows is one conversation.
/// Building a `ConversationModel` per window meant a reply streaming in one
/// window was invisible in the other, and two windows could start concurrent
/// runs against the same stored history.
@Observable
public final class AssistantConversationStore {
    public private(set) var conversations: [ConversationModel] = []

    public init(conversations: [ConversationModel] = []) {
        self.conversations = conversations
    }

    public func conversation(id: ConversationModel.ID) -> ConversationModel? {
        conversations.first { $0.id == id }
    }

    public func insert(_ conversation: ConversationModel) {
        guard !conversations.contains(where: { $0.id == conversation.id }) else { return }
        conversations.insert(conversation, at: 0)
    }

    /// Forks use the same lowest-free numbering as duplicated terminal workspaces:
    /// `Title (1)`, `Title (2)`, and a vacated number can be reused. Forking a
    /// fork continues the original sequence instead of producing `(1) (1)`.
    public func nextForkTitle(for source: ConversationModel) -> String {
        let sourceTitle = source.derivedTitle
        let root = forkRoot(for: sourceTitle, sourceID: source.id)
        let taken = Set(conversations.map(\.derivedTitle))
        var index = 1
        while taken.contains(ConversationModel.numberedForkTitle(base: root, index: index)) {
            index += 1
        }
        return ConversationModel.numberedForkTitle(base: root, index: index)
    }

    private func forkRoot(for title: String, sourceID: UUID) -> String {
        guard
            let range = title.range(
                of: #" \([0-9]+\)$"#, options: .regularExpression
            )
        else { return title }
        let candidate = String(title[..<range.lowerBound])
        let belongsToExistingSequence = conversations.contains { conversation in
            guard conversation.id != sourceID else { return false }
            let other = conversation.derivedTitle
            if other == candidate { return true }
            guard
                let suffix = other.range(
                    of: #" \([0-9]+\)$"#, options: .regularExpression
                )
            else { return false }
            return other[..<suffix.lowerBound] == candidate
        }
        return belongsToExistingSequence ? candidate : title
    }

    /// Removes one conversation and hands back where it was, so each window can
    /// move its own selection to whatever took its place.
    @discardableResult
    public func remove(_ id: ConversationModel.ID) -> Int? {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return nil }
        conversations[index].stop()
        conversations.remove(at: index)
        return index
    }

    public func restore(_ stored: [StoredAgentConversation], modelSelections: [UUID: AIModelRef] = [:]) {
        let existingIDs = Set(conversations.map(\.id))
        let restored = stored.filter { !existingIDs.contains($0.id) }.map { value in
            let conversation = ConversationModel(
                id: value.id,
                messages: value.messages.compactMap { message in
                    guard !message.isCompaction else { return nil }
                    return switch message.role {
                    case .user:
                        ChatMessage(
                            id: message.id, role: .user,
                            text: message.authoredText ?? ContextChip.visiblePrompt(in: message.text),
                            contextChips: ContextChip.visibleReferences(
                                in: message.text, images: message.images,
                                contextAttachments: message.contextAttachments
                            ),
                            images: message.images,
                            createdAt: message.createdAt
                        )
                    case .assistant:
                        ChatMessage(
                            id: message.id, role: .assistant, text: message.text,
                            reasoning: message.reasoning,
                            createdAt: message.createdAt
                        )
                    case .tool: nil
                    }
                },
                // Tool rows are dropped from the visible list because they are
                // drawn as cards, but the model still needs them next turn.
                transcript: value.modelTranscript ?? value.messages,
                runState: value.lastRunState,
                messageRunIDs: value.messageRunIDs,
                runs: value.runs,
                compactionRecords: value.compactions,
                createdAt: value.metadata.createdAt,
                updatedAt: value.metadata.updatedAt,
                sortIndex: value.metadata.sortIndex
            )
            // Empty is "never summarized", not a name of nothing — `derivedTitle`
            // has to be able to tell those apart to fall back.
            conversation.title = value.title.isEmpty ? nil : value.title
            conversation.model = modelSelections[value.id]
            conversation.customTitle =
                value.metadata.customTitle.isEmpty
                ? nil : value.metadata.customTitle
            conversation.isPinned = value.metadata.isPinned
            conversation.archivedAt = value.metadata.archivedAt
            conversation.toolCards = value.toolCards.map { card in
                let state: AgentToolCard.State
                if card.result?.isInterrupted == true {
                    state = .interrupted
                } else if card.result?.isError == true {
                    state = .failed
                } else if card.result != nil || card.state == "finished" {
                    state = .completed
                }
                // Not `.running`, which is what this used to restore to. Every
                // unfinished run is marked interrupted at launch, so a card
                // that was mid-flight when the process died is not running
                // now and never will be — it came back as a spinner that
                // nothing would ever stop.
                else if card.state == "started" {
                    state = .interrupted
                } else {
                    state = .proposed
                }
                return AgentToolCard(
                    invocation: card.invocation, descriptor: card.descriptor,
                    state: state, result: card.result, review: card.review
                )
            }
            return conversation
        }
        conversations = restored + conversations
    }
}

/// Window-local navigation over the app's conversations.
///
/// The list is shared; only the selection is per window, which is what lets two
/// windows show different chats from the same set without duplicating any of
/// them.
@Observable
public final class AssistantLibraryModel {
    private var store: AssistantConversationStore
    public var selectedConversationID: ConversationModel.ID?
    public var modelSelections: AssistantModelSelectionController? {
        didSet { modelSelections?.seed(draftConversation) }
    }
    /// Window-local scratch space for the Assistant destination's New Chat surface.
    /// It is promoted into the shared history only after its first real send,
    /// so merely entering Assistant never creates an empty list row.
    public private(set) var draftConversation = ConversationModel()

    public init(store: AssistantConversationStore = AssistantConversationStore()) {
        self.store = store
        selectedConversationID = nil
    }

    public var conversations: [ConversationModel] { store.conversations }
    public var pinnedConversations: [ConversationModel] {
        conversations.filter { !$0.isArchived && $0.isPinned }
            .sorted(by: Self.manualOrder)
    }
    public var activeConversations: [ConversationModel] {
        conversations.filter { !$0.isArchived && !$0.isPinned }
            .sorted(by: Self.manualOrder)
    }
    public var archivedConversations: [ConversationModel] {
        conversations.filter(\.isArchived).sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func manualOrder(_ lhs: ConversationModel, _ rhs: ConversationModel) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Produces one complete, normalized order for both live groups. Removing
    /// the source before resolving `before` makes the target mean the same thing
    /// whether the conversation crosses the Pinned boundary or stays in place.
    public func orderUpdates(
        moving id: ConversationModel.ID,
        toPinned: Bool,
        before nextID: ConversationModel.ID?
    ) -> [StoredAgentConversationOrder]? {
        guard let source = conversation(id: id), !source.isArchived else { return nil }

        var pinned = pinnedConversations.filter { $0.id != id }
        var chats = activeConversations.filter { $0.id != id }
        if toPinned {
            let index =
                nextID.flatMap { next in pinned.firstIndex { $0.id == next } }
                ?? pinned.endIndex
            pinned.insert(source, at: index)
        } else {
            let index =
                nextID.flatMap { next in chats.firstIndex { $0.id == next } }
                ?? chats.endIndex
            chats.insert(source, at: index)
        }

        return pinned.enumerated().map {
            StoredAgentConversationOrder(id: $0.element.id, isPinned: true, sortIndex: Double($0.offset))
        }
            + chats.enumerated().map {
                StoredAgentConversationOrder(id: $0.element.id, isPinned: false, sortIndex: Double($0.offset))
            }
    }

    public func applyOrder(_ updates: [StoredAgentConversationOrder]) {
        for update in updates {
            guard let conversation = conversation(id: update.id) else { continue }
            conversation.isPinned = update.isPinned
            conversation.sortIndex = update.sortIndex
        }
    }

    /// Joins the app-wide store, carrying over anything this window made before
    /// it was registered. Windows are registered on appear, so in practice that
    /// is nothing — but silently dropping a conversation would be worse than the
    /// two lines it costs to keep it.
    public func adopt(_ shared: AssistantConversationStore) {
        guard store !== shared else { return }
        for conversation in store.conversations.reversed() { shared.insert(conversation) }
        store = shared
        if let selectedConversationID,
            shared.conversation(id: selectedConversationID) == nil
        {
            self.selectedConversationID = nil
        }
    }

    public var selectedConversation: ConversationModel? {
        guard let selectedConversationID else { return nil }
        return conversation(id: selectedConversationID)
    }

    public func conversation(id: ConversationModel.ID) -> ConversationModel? {
        store.conversation(id: id)
    }

    @discardableResult
    public func createConversation() -> ConversationModel {
        let conversation = newConversation()
        store.insert(conversation)
        selectedConversationID = conversation.id
        return conversation
    }

    public func insertAndSelect(_ conversation: ConversationModel) {
        store.insert(conversation)
        selectedConversationID = conversation.id
    }

    /// Shows New Chat without manufacturing an empty history item. Keeping one
    /// scratch model also preserves an unfinished draft while the user briefly
    /// opens an older conversation and comes back.
    @discardableResult
    public func selectNewConversation() -> ConversationModel {
        selectedConversationID = nil
        return draftConversation
    }

    /// Starts a deliberately fresh New Chat surface. Platform navigation can
    /// use this for an explicit New action, while `selectNewConversation()`
    /// continues to preserve a draft when merely navigating away and back.
    @discardableResult
    public func resetDraftConversation() -> ConversationModel {
        selectedConversationID = nil
        draftConversation = newConversation()
        return draftConversation
    }

    /// Promotes the New Chat scratch model on its first send, then prepares a
    /// fresh scratch model for the next visit to New Chat.
    @discardableResult
    public func startDraftConversation() -> ConversationModel? {
        let conversation = draftConversation
        guard let started = startConversation(conversation) else { return nil }
        draftConversation = newConversation()
        return started
    }

    public func canPromote(_ conversation: ConversationModel) -> Bool {
        !conversations.contains(where: { $0.id == conversation.id })
    }

    /// Publishes a conversation only after its first user turn and immutable run
    /// capture have already succeeded.
    @discardableResult
    public func promoteCapturedConversation(_ conversation: ConversationModel) -> Bool {
        guard canPromote(conversation), !conversation.transcript.isEmpty else { return false }
        store.insert(conversation)
        selectedConversationID = conversation.id
        return true
    }

    @discardableResult
    public func promoteCapturedDraftConversation(_ conversation: ConversationModel) -> Bool {
        guard conversation === draftConversation,
            promoteCapturedConversation(conversation)
        else { return false }
        draftConversation = newConversation()
        return true
    }

    private func newConversation() -> ConversationModel {
        let conversation = ConversationModel()
        modelSelections?.seed(conversation)
        return conversation
    }

    /// Promotes the sidebar's scratch conversation into history on its first
    /// real send. Empty drafts remain ephemeral and never create blank rows.
    @discardableResult
    public func startConversation(_ conversation: ConversationModel) -> ConversationModel? {
        guard conversation.canSendDraft else { return nil }
        guard !conversations.contains(where: { $0.id == conversation.id }) else { return nil }

        conversation.sendDraft()
        store.insert(conversation)
        selectedConversationID = conversation.id
        return conversation
    }

    public func select(_ id: ConversationModel.ID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
    }

    public func delete(_ id: ConversationModel.ID) {
        store.remove(id)
        guard selectedConversationID == id else { return }
        // Archived chats no longer live in the ordinary navigator. Deleting a
        // live chat must therefore never select a hidden archived row as its
        // successor; return to the most relevant visible chat, or New Chat.
        selectedConversationID = (pinnedConversations + activeConversations).first?.id
    }

    public func restore(_ stored: [StoredAgentConversation], modelSelections: [UUID: AIModelRef] = [:]) {
        store.restore(stored, modelSelections: modelSelections)
        if let selectedConversationID,
            conversation(id: selectedConversationID) == nil
        {
            self.selectedConversationID = nil
        }
    }

    // MARK: - Search

    /// Which half of the list a search runs over. Active and archived are
    /// separate destinations, so a match in one must never surface in the other
    /// — finding an archived chat while looking at live ones, and then opening
    /// it, would silently take the user somewhere they did not navigate.
    public nonisolated enum SearchScope: Sendable {
        case active
        case archived
    }

    /// Titles and visible message bodies, and deliberately nothing else.
    ///
    /// `ChatMessage.reasoning`, the tool cards and the raw `transcript` are all
    /// excluded: they hold hidden thinking, unredacted tool output and whatever
    /// a command printed, none of which the user chose to put on screen. A
    /// search field is not a way to read them.
    public func search(_ query: String, scope: SearchScope) -> [ConversationModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates: [ConversationModel] =
            switch scope {
            case .active: pinnedConversations + activeConversations
            case .archived: archivedConversations
            }
        guard !trimmed.isEmpty else { return candidates }
        return candidates.filter { $0.matches(trimmed) }
    }
}

extension ConversationModel {
    /// See `AssistantLibraryModel.search(_:scope:)` for what is deliberately
    /// not searched here.
    public func matches(_ query: String) -> Bool {
        if derivedTitle.localizedCaseInsensitiveContains(query) { return true }
        return messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
    }
}

import Foundation

nonisolated enum AgentConversationPersistenceError: LocalizedError, Sendable {
    case conversationNotFound
    case messageNotFound
    case conversationAlreadyExists

    var errorDescription: String? {
        switch self {
        case .conversationNotFound:
            String(localized: "The conversation no longer exists.")
        case .messageNotFound:
            String(localized: "The message is no longer available to edit.")
        case .conversationAlreadyExists:
            String(localized: "The fork could not be created because its identifier already exists.")
        }
    }
}

nonisolated protocol AgentRunPersisting: Sendable {
    func save(_ snapshot: AgentRunSnapshot) async throws
    func record(_ event: AgentEvent, runID: UUID) async throws
    func loadConversations() async throws -> [StoredAgentConversation]
    func deleteConversation(_ id: UUID) async throws
    /// Records the generated summary. Separate from `save` because it arrives
    /// after the run that produced it has already been written, and because a
    /// run snapshot is not where a name for the whole conversation belongs.
    func setTitle(_ title: String, conversationID: UUID) async throws
    func setConversationMetadata(
        _ metadata: StoredAgentConversationMetadata, conversationID: UUID
    ) async throws
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) async throws
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) async throws
    func createConversation(_ conversation: StoredAgentConversation) async throws
}

// No default implementations here, deliberately. A protocol extension that
// satisfies a requirement is also the thing that *silently* satisfies it when a
// conformer's own method stops being a valid witness — an isolation change, a
// renamed label — and run history would then be dropped with no diagnostic.
// Both conformers implement the whole protocol.

nonisolated struct StoredAgentConversation: Sendable {
    var id: UUID
    var messages: [AgentTranscriptMessage]
    /// UI-only ownership restored from message rows. Keeping it outside the
    /// transcript prevents run identifiers leaking into provider requests.
    var messageRunIDs: [UUID: UUID] = [:]
    var runs: [AgentRunSummary] = []
    var toolCards: [StoredAgentToolCard] = []
    var lastRunState: AgentRunState
    /// The generated summary, or empty for a conversation that never got one.
    var title: String = ""
    var metadata = StoredAgentConversationMetadata()
}

nonisolated struct StoredAgentConversationMetadata: Hashable, Sendable {
    var customTitle = ""
    var isPinned = false
    /// Manual order inside the pinned or ordinary group. Older rows have no
    /// value and fall back to their last activity without needing a data rewrite.
    var sortIndex: Double?
    var archivedAt: Date?
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

nonisolated struct StoredAgentConversationOrder: Hashable, Sendable {
    let id: UUID
    let isPinned: Bool
    let sortIndex: Double
}

nonisolated struct StoredAgentToolCard: Sendable {
    var invocation: AgentToolInvocation
    var descriptor: AgentToolDescriptor
    var state: String
    var result: AgentToolResult?
    var review: SecurityReviewDecision?
}

actor InMemoryAgentRunRepository: AgentRunPersisting {
    private var snapshots: [UUID: AgentRunSnapshot] = [:]
    private var titles: [UUID: String] = [:]
    private var storedToolCards: [UUID: [StoredAgentToolCard]] = [:]
    private var deletedConversationIDs = Set<UUID>()
    private var metadata: [UUID: StoredAgentConversationMetadata] = [:]
    func save(_ snapshot: AgentRunSnapshot) {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else { return }
        snapshots[snapshot.id] = snapshot
    }
    func record(_ event: AgentEvent, runID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] {
        Dictionary(grouping: snapshots.values, by: \.conversationID).map { id, runs in
            let ordered = runs.sorted { $0.startedAt < $1.startedAt }
            var seen = Set<UUID>()
            let messages = ordered.flatMap(\.messages).filter { seen.insert($0.id).inserted }
            var messageRunIDs: [UUID: UUID] = [:]
            for run in ordered {
                for message in run.messages where messageRunIDs[message.id] == nil {
                    messageRunIDs[message.id] = run.id
                }
            }
            return StoredAgentConversation(
                id: id, messages: messages, messageRunIDs: messageRunIDs,
                runs: ordered.map {
                    AgentRunSummary(
                        id: $0.id, state: $0.state, startedAt: $0.startedAt,
                        finishedAt: $0.finishedAt
                    )
                },
                toolCards: storedToolCards[id] ?? [],
                lastRunState: ordered.last?.state ?? .completed,
                title: titles[id] ?? "",
                metadata: metadata[id] ?? StoredAgentConversationMetadata()
            )
        }.sorted { $0.metadata.updatedAt > $1.metadata.updatedAt }
    }
    func snapshot(_ id: UUID) -> AgentRunSnapshot? { snapshots[id] }
    func setTitle(_ title: String, conversationID: UUID) {
        guard !deletedConversationIDs.contains(conversationID) else { return }
        titles[conversationID] = title
    }
    func setConversationMetadata(
        _ value: StoredAgentConversationMetadata, conversationID: UUID
    ) throws {
        guard !deletedConversationIDs.contains(conversationID),
            snapshots.values.contains(where: { $0.conversationID == conversationID })
        else { throw AgentConversationPersistenceError.conversationNotFound }
        metadata[conversationID] = value
    }
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) throws {
        let ids = Set(updates.map(\.id))
        guard updates.count == ids.count,
            ids.allSatisfy({ id in
                !deletedConversationIDs.contains(id)
                    && snapshots.values.contains(where: { $0.conversationID == id })
            })
        else { throw AgentConversationPersistenceError.conversationNotFound }
        for update in updates {
            var value = metadata[update.id] ?? StoredAgentConversationMetadata()
            value.isPinned = update.isPinned
            value.sortIndex = update.sortIndex
            metadata[update.id] = value
        }
    }
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) throws {
        let ordered = snapshots.values.filter { $0.conversationID == id }
            .sorted { $0.startedAt < $1.startedAt }
        guard let target = ordered.first(where: { snapshot in
            snapshot.messages.contains { $0.id == messageID }
        }) else { throw AgentConversationPersistenceError.messageNotFound }
        let targetStart = target.startedAt
        let removedRunIDs = Set(ordered.filter { $0.startedAt >= targetStart }.map(\.id))
        snapshots = snapshots.filter {
            $0.value.conversationID != id || $0.value.startedAt < targetStart
        }
        storedToolCards[id]?.removeAll { removedRunIDs.contains($0.invocation.runID) }
        let replacement = AgentRunSnapshot(
            conversationID: id, state: .completed,
            permissionMode: .askForApproval, messages: [message],
            startedAt: message.createdAt, finishedAt: message.createdAt
        )
        snapshots[replacement.id] = replacement
    }
    func createConversation(_ conversation: StoredAgentConversation) throws {
        guard !deletedConversationIDs.contains(conversation.id),
            !snapshots.values.contains(where: { $0.conversationID == conversation.id })
        else { throw AgentConversationPersistenceError.conversationAlreadyExists }
        let runs = conversation.runs.isEmpty
            ? [AgentRunSummary(
                id: UUID(), state: conversation.lastRunState,
                startedAt: conversation.metadata.createdAt,
                finishedAt: conversation.metadata.updatedAt
            )]
            : conversation.runs
        let fallbackRunID = runs[0].id
        for run in runs {
            snapshots[run.id] = AgentRunSnapshot(
                id: run.id, conversationID: conversation.id, state: run.state,
                permissionMode: .askForApproval,
                messages: conversation.messages.filter {
                    (conversation.messageRunIDs[$0.id] ?? fallbackRunID) == run.id
                },
                startedAt: run.startedAt, finishedAt: run.finishedAt
            )
        }
        storedToolCards[conversation.id] = conversation.toolCards
        titles[conversation.id] = conversation.title
        metadata[conversation.id] = conversation.metadata
    }
    func deleteConversation(_ id: UUID) {
        deletedConversationIDs.insert(id)
        titles.removeValue(forKey: id)
        metadata.removeValue(forKey: id)
        storedToolCards.removeValue(forKey: id)
        snapshots = snapshots.filter { $0.value.conversationID != id }
    }
}

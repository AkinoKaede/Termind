import Foundation

nonisolated protocol AgentRunPersisting: Sendable {
    func save(_ snapshot: AgentRunSnapshot) async throws
    func record(_ event: AgentEvent, runID: UUID) async throws
    func loadConversations() async throws -> [StoredAgentConversation]
    func deleteConversation(_ id: UUID) async throws
    /// Records the generated summary. Separate from `save` because it arrives
    /// after the run that produced it has already been written, and because a
    /// run snapshot is not where a name for the whole conversation belongs.
    func setTitle(_ title: String, conversationID: UUID) async throws
}

// No default implementations here, deliberately. A protocol extension that
// satisfies a requirement is also the thing that *silently* satisfies it when a
// conformer's own method stops being a valid witness — an isolation change, a
// renamed label — and run history would then be dropped with no diagnostic.
// Both conformers implement the whole protocol.

nonisolated struct StoredAgentConversation: Sendable {
    var id: UUID
    var messages: [AgentTranscriptMessage]
    var toolCards: [StoredAgentToolCard] = []
    var lastRunState: AgentRunState
    /// The generated summary, or empty for a conversation that never got one.
    var title: String = ""
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
    private var deletedConversationIDs = Set<UUID>()
    func save(_ snapshot: AgentRunSnapshot) {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else { return }
        snapshots[snapshot.id] = snapshot
    }
    func record(_ event: AgentEvent, runID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func snapshot(_ id: UUID) -> AgentRunSnapshot? { snapshots[id] }
    func setTitle(_ title: String, conversationID: UUID) {
        guard !deletedConversationIDs.contains(conversationID) else { return }
        titles[conversationID] = title
    }
    func title(_ conversationID: UUID) -> String? { titles[conversationID] }
    func deleteConversation(_ id: UUID) {
        deletedConversationIDs.insert(id)
        titles.removeValue(forKey: id)
        snapshots = snapshots.filter { $0.value.conversationID != id }
    }
}

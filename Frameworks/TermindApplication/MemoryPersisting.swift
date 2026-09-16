import AgentKit
import Foundation

public nonisolated protocol MemoryPersisting: AgentMemoryAccessing {
    func snapshot(for conversationID: UUID) async throws -> String
    func replaceHistory(_ conversations: [StoredAgentConversation]) async throws
    func rebuildHistoryIndex() async throws
    func lastReviewedMessage(_ conversationID: UUID) async throws -> UUID?
    func markReviewed(_ messageID: UUID, conversationID: UUID) async throws
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID
    ) async throws -> AgentMemoryState?
    func replaceTarget(_ target: AgentMemoryTarget, text: String) async throws -> AgentMemoryState
    func close() async throws
    func destroy() async throws
}

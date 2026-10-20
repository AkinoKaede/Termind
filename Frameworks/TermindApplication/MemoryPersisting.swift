// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

public nonisolated protocol MemoryPersisting: AgentMemoryAccessing {
    func prepareSession(_ conversationID: UUID) async throws
    func replaceHistory(_ conversations: [StoredAgentConversation]) async throws
    func rebuildHistoryIndex() async throws
    func recordActivity(_ id: UUID, sourceMessageID: UUID, kind: MemoryActivityKind, conversationID: UUID) async throws
        -> MemoryLearningProgress
    func learningProgress(_ conversationID: UUID) async throws -> MemoryLearningProgress
    func correctionWasReviewed(_ messageID: UUID, conversationID: UUID) async throws -> Bool
    func applyCorrection(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID
    ) async throws -> AgentMemoryState?
    func applyReview(
        _ operations: [AgentMemoryOperation], expected: AgentMemoryState, messageID: UUID, conversationID: UUID,
        reviewedActivityIDs: [UUID]
    ) async throws -> AgentMemoryState?
    func replaceTarget(_ target: AgentMemoryTarget, text: String) async throws -> AgentMemoryState
    func memoryReferenceDates() async throws -> [UUID: Date]
    func recordMemoryReferences(_ ids: [UUID], at date: Date) async throws
    func close() async throws
    func destroy() async throws
}

public nonisolated enum MemoryActivityKind: String, Equatable, Sendable { case turn, tool }

public nonisolated struct MemoryLearningEvent: Sendable {
    public var id: UUID
    public var sourceMessageID: UUID
    public init(id: UUID, sourceMessageID: UUID) {
        self.id = id
        self.sourceMessageID = sourceMessageID
    }
}

public nonisolated struct MemoryLearningProgress: Sendable {
    public var lastReviewedMessage: UUID?
    public var turns: Int
    public var tools: Int
    public var events: [MemoryLearningEvent]
    public init(
        lastReviewedMessage: UUID? = nil, turns: Int = 0, tools: Int = 0,
        events: [MemoryLearningEvent] = []
    ) {
        self.lastReviewedMessage = lastReviewedMessage
        self.turns = turns
        self.tools = tools
        self.events = events
    }
}

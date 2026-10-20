// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Only successful history changes schedule indexing; disabled memory performs no additional I/O.
@MainActor public final class MemoryIndexedAgentRepository: AgentRunPersisting {
    private let base: any AgentRunPersisting
    private let memory: MemoryModel
    public init(base: any AgentRunPersisting, memory: MemoryModel) {
        self.base = base
        self.memory = memory
        memory.attachHistory(base)
    }
    public func save(_ snapshot: AgentRunSnapshot) async throws {
        try await base.save(snapshot)
        if snapshot.state.isTerminal { memory.historyChanged() }
    }
    public func record(_ event: AgentEvent, runID: UUID) async throws { try await base.record(event, runID: runID) }
    public func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) async throws {
        try await base.persistCompaction(record, conversationID: conversationID)
    }
    public func loadConversations() async throws -> [StoredAgentConversation] { try await base.loadConversations() }
    public func deleteConversation(_ id: UUID) async throws {
        try await base.deleteConversation(id)
        memory.invalidateLearning(for: id)
        memory.historyChanged()
    }
    public func setTitle(_ title: String, conversationID: UUID) async throws {
        try await base.setTitle(title, conversationID: conversationID)
        memory.historyChanged()
    }
    public func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) async throws
    {
        try await base.setConversationMetadata(metadata, conversationID: conversationID)
    }
    public func reorderConversations(_ updates: [StoredAgentConversationOrder]) async throws {
        try await base.reorderConversations(updates)
    }
    public func truncateConversation(_ id: UUID, fromUserMessageID: UUID, replacingWith: AgentTranscriptMessage)
        async throws
    {
        try await base.truncateConversation(id, fromUserMessageID: fromUserMessageID, replacingWith: replacingWith)
        memory.invalidateLearning(for: id)
        memory.historyChanged()
    }
    public func createConversation(_ conversation: StoredAgentConversation) async throws {
        try await base.createConversation(conversation)
        memory.historyChanged()
    }
}

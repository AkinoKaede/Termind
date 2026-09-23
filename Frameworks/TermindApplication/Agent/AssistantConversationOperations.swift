import AgentKit
import Foundation

/// Durable conversation mutations commit before changing observable state.
@MainActor
public final class AssistantConversationOperations {
    private let repository: any AgentRunPersisting
    private var pending = Set<UUID>()

    public init(repository: any AgentRunPersisting) { self.repository = repository }

    public func setArchived(_ value: Bool, conversation: ConversationModel) async throws {
        await conversation.cancelPendingAgentPreparationAndWait()
        guard !conversation.isStreaming, !conversation.isCompacting,
            pending.insert(conversation.id).inserted
        else { return }
        conversation.isHistoryChanging = true
        defer {
            pending.remove(conversation.id)
            conversation.isHistoryChanging = false
        }
        var metadata = conversation.metadata
        metadata.archivedAt = value ? .now : nil
        if value { metadata.isPinned = false }
        try await repository.setConversationMetadata(metadata, conversationID: conversation.id)
        conversation.archivedAt = metadata.archivedAt
        conversation.isPinned = metadata.isPinned
    }

    public func rename(_ conversation: ConversationModel, title: String) async throws {
        let title = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !title.isEmpty, pending.insert(conversation.id).inserted else { return }
        conversation.isHistoryChanging = true
        defer {
            pending.remove(conversation.id)
            conversation.isHistoryChanging = false
        }
        var metadata = conversation.metadata
        metadata.customTitle = title
        try await repository.setConversationMetadata(metadata, conversationID: conversation.id)
        conversation.customTitle = title
    }

    public func move(
        _ conversation: ConversationModel, pinned: Bool, before nextID: UUID?, library: AssistantLibraryModel
    ) async throws {
        guard !conversation.isArchived,
            pending.insert(conversation.id).inserted
        else { return }
        conversation.isHistoryChanging = true
        defer {
            pending.remove(conversation.id)
            conversation.isHistoryChanging = false
        }
        guard let updates = library.orderUpdates(moving: conversation.id, toPinned: pinned, before: nextID) else {
            return
        }
        try await repository.reorderConversations(updates)
        library.applyOrder(updates)
    }

    @discardableResult
    public func delete(_ conversation: ConversationModel) async throws -> (deleted: Bool, cleanupError: String?) {
        await conversation.cancelPendingAgentPreparationAndWait()
        guard !conversation.isStreaming, !conversation.isCompacting,
            pending.insert(conversation.id).inserted
        else { return (false, nil) }
        conversation.isHistoryChanging = true
        defer {
            pending.remove(conversation.id)
            conversation.isHistoryChanging = false
        }
        try await repository.deleteConversation(conversation.id)
        do {
            try await AgentScratchWorkspace(
                conversationID: conversation.id,
                applicationName: TermindAgentPolicy.scratchDirectoryName
            ).removeScope()
            return (true, nil)
        } catch { return (true, error.localizedDescription) }
    }

    public func fork(_ source: ConversationModel, at messageID: UUID, title: String) async throws -> ConversationModel?
    {
        guard let fork = source.forked(throughAssistantMessage: messageID, title: title),
            pending.insert(source.id).inserted
        else { return nil }
        source.isHistoryChanging = true
        defer {
            pending.remove(source.id)
            source.isHistoryChanging = false
        }
        let stored = StoredAgentConversation(
            id: fork.id, messages: fork.transcript, modelTranscript: fork.transcript,
            compactions: fork.compactionRecords, messageRunIDs: fork.messageRunIDs,
            runs: Array(fork.runSummaries.values),
            toolCards: fork.toolCards.map {
                StoredAgentToolCard(
                    invocation: $0.invocation, descriptor: $0.descriptor,
                    state: $0.state.rawValue, result: $0.result, review: $0.review)
            }, lastRunState: .completed, title: "", metadata: fork.metadata)
        do {
            try await Task.detached(priority: .utility) {
                try AgentScratchWorkspace.copyScope(
                    from: source.id, to: fork.id,
                    applicationName: TermindAgentPolicy.scratchDirectoryName)
            }.value
            try await repository.createConversation(stored)
            return fork
        } catch {
            try? await AgentScratchWorkspace(
                conversationID: fork.id, applicationName: TermindAgentPolicy.scratchDirectoryName
            ).removeScope()
            throw error
        }
    }

    public func edit(
        _ conversation: ConversationModel, messageID: UUID, text: String,
        contextSnapshot: AgentTurnContextSnapshot? = nil
    ) async throws -> ConversationModel
        .ComposedUserTurn?
    {
        guard var replacement = conversation.editedUserMessage(messageID, authoredText: text) else { return nil }
        replacement.contextSnapshot = contextSnapshot
        return try await edit(conversation, messageID: messageID, replacement: replacement)
    }

    public func edit(
        _ conversation: ConversationModel, messageID: UUID,
        replacement: AgentTranscriptMessage
    ) async throws -> ConversationModel.ComposedUserTurn? {
        try Task.checkCancellation()
        guard conversation.canApplyUserMessageEdit(messageID, replacement: replacement),
            pending.insert(conversation.id).inserted
        else { return nil }
        conversation.isHistoryChanging = true
        defer {
            pending.remove(conversation.id)
            conversation.isHistoryChanging = false
        }
        try Task.checkCancellation()
        try await repository.truncateConversation(
            conversation.id, fromUserMessageID: messageID, replacingWith: replacement)
        conversation.isHistoryChanging = false
        return conversation.applyPersistedUserMessageEdit(messageID, replacement: replacement)
    }
}

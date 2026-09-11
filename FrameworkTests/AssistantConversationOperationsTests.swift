import AgentKit
import Foundation
import TermindApplication
import Testing

@Suite @MainActor
struct AssistantConversationOperationsTests {
    private func fixture() async throws -> (
        InMemoryAgentRunRepository, ConversationModel, AssistantConversationOperations
    ) {
        let repository = InMemoryAgentRunRepository()
        let message = AgentTranscriptMessage(role: .user, text: "Inspect this server")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: message.id, role: .user, text: message.text)], transcript: [message])
        try await repository.createConversation(
            .init(id: conversation.id, messages: [message], lastRunState: .completed, metadata: conversation.metadata))
        return (repository, conversation, AssistantConversationOperations(repository: repository))
    }

    @Test func archiveClearsPinPersistsAndRestoresReadOnlyHistory() async throws {
        let (repository, conversation, operations) = try await fixture()
        conversation.isPinned = true
        try await operations.setArchived(true, conversation: conversation)
        #expect(conversation.isArchived)
        #expect(!conversation.isPinned)
        #expect(!conversation.canEditUserMessage(conversation.messages[0].id))
        let store = AssistantConversationStore()
        store.restore(await repository.loadConversations())
        let restored = try #require(store.conversations.first)
        #expect(restored.isArchived)
        #expect(restored.messages.first?.text == "Inspect this server")
        try await operations.setArchived(false, conversation: restored)
        #expect(!restored.isArchived)
        #expect(!restored.isPinned)
        #expect(restored.canEditUserMessage(restored.messages[0].id))
    }

    @Test func activeRunCannotBeArchivedOrReordered() async throws {
        let (repository, conversation, operations) = try await fixture()
        conversation.handle(.runState(.running))
        try await operations.setArchived(true, conversation: conversation)
        #expect(!conversation.isArchived)
        #expect(await repository.loadConversations().first?.metadata.archivedAt == nil)
    }

    @Test func storageFailureDoesNotChangeMetadata() async throws {
        let conversation = ConversationModel()
        conversation.isPinned = true
        let operations = AssistantConversationOperations(repository: RejectingConversationRepository())
        await #expect(throws: CocoaError.self) { try await operations.setArchived(true, conversation: conversation) }
        #expect(!conversation.isArchived)
        #expect(conversation.isPinned)
        await #expect(throws: CocoaError.self) { try await operations.rename(conversation, title: "Changed") }
        #expect(conversation.customTitle == nil)
    }

    @Test func archiveSearchIsSeparateFromActiveSearch() async throws {
        let (_, conversation, operations) = try await fixture()
        let library = AssistantLibraryModel()
        library.insertAndSelect(conversation)
        try await operations.setArchived(true, conversation: conversation)
        #expect(library.search("Inspect", scope: .active).isEmpty)
        #expect(library.search("Inspect", scope: .archived).map(\.id) == [conversation.id])
    }

    @Test func attachmentCancellationIgnoresLateResultAndDoesNotAffectAnotherDraft() {
        let first = ConversationModel()
        let second = ConversationModel()
        second.composer.draft = "keep this draft"
        let pending = first.beginAttachmentImport(label: "notes.txt")!
        first.cancelAttachmentImport(pending.id)
        first.finishAttachmentImport(pending.id, with: ContextChip(kind: .file, label: "notes.txt", content: "late"))
        #expect(first.composer.attachments.isEmpty)
        #expect(first.composer.pendingAttachments.isEmpty)
        #expect(second.composer.draft == "keep this draft")
    }

    @Test func attachmentLimitIncludesPendingImports() {
        let conversation = ConversationModel()
        for index in 0..<ContextAttachmentLoading.maximumAttachments {
            #expect(conversation.beginAttachmentImport(label: "\(index)") != nil)
        }
        #expect(conversation.beginAttachmentImport(label: "overflow") == nil)
        #expect(conversation.composer.attachmentImportError != nil)
    }

    @Test
    func immediateStopCannotStartAQueuedRuntime() async {
        let calls = AssistantModelCalls()
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: CountingAssistantModel(calls: calls), tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("test") }))
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "go", permissionMode: .askForApproval))
        conversation.stop()
        for _ in 0..<20 { await Task.yield() }
        #expect(await calls.count == 0)
        #expect(!conversation.isStreaming)
    }

    @Test func deletingRemovesDurableConversation() async throws {
        let (repository, conversation, operations) = try await fixture()
        try await operations.delete(conversation)
        #expect(await repository.loadConversations().isEmpty)
    }
}

private actor RejectingConversationRepository: AgentRunPersisting {
    func save(_ snapshot: AgentRunSnapshot) throws { throw CocoaError(.fileWriteNoPermission) }
    func record(_ event: AgentEvent, runID: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
    func setTitle(_ title: String, conversationID: UUID) throws { throw CocoaError(.fileWriteNoPermission) }
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID, replacingWith message: AgentTranscriptMessage
    ) throws { throw CocoaError(.fileWriteNoPermission) }
    func createConversation(_ conversation: StoredAgentConversation) throws { throw CocoaError(.fileWriteNoPermission) }
}

private actor AssistantModelCalls {
    var count = 0
    func called() { count += 1 }
}

private struct CountingAssistantModel: AgentModelStreaming {
    let calls: AssistantModelCalls
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.called()
                continuation.yield(.finished(.completed))
                continuation.finish()
            }
        }
    }
}

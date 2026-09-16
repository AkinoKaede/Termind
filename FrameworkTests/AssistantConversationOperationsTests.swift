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

    @Test func restoreMergesHistoryCreatedWhileTheRepositoryWasLoading() {
        let store = AssistantConversationStore()
        let live = ConversationModel(messages: [ChatMessage(role: .user, text: "Created while loading")])
        store.insert(live)
        let persistedID = UUID()
        let persistedMessage = AgentTranscriptMessage(role: .user, text: "Persisted history")

        store.restore([
            StoredAgentConversation(
                id: persistedID,
                messages: [persistedMessage],
                lastRunState: .completed,
                metadata: StoredAgentConversationMetadata()
            )
        ])

        #expect(store.conversations.map(\.id) == [persistedID, live.id])
    }

    @Test(arguments: [AgentRunState.running, .waitingForApproval, .idle], [false, true])
    func activeRunOrCompactionCannotBeArchivedOrDeleted(state: AgentRunState, compacting: Bool) async throws {
        let (repository, conversation, operations) = try await fixture()
        guard state != .idle || compacting else { return }
        conversation.handle(.runState(state))
        if compacting { conversation.beginCompaction() }
        try await operations.setArchived(true, conversation: conversation)
        let result = try await operations.delete(conversation)
        #expect(!conversation.isArchived)
        #expect(!result.deleted)
        #expect(conversation.runState == state)
        #expect(conversation.isCompacting == compacting)
        #expect(await repository.loadConversations().count == 1)
        #expect(await repository.loadConversations().first?.metadata.archivedAt == nil)
    }

    @Test(arguments: [AgentRunState.running, .waitingForApproval, .idle], [false, true])
    func orderingDuringActivityPersistsWithoutChangingTheLiveConversation(
        state: AgentRunState, compacting: Bool
    ) async throws {
        let (repository, conversation, operations) = try await fixture()
        conversation.sortIndex = 2
        let peer = ConversationModel(sortIndex: 0)
        let pinned = ConversationModel(sortIndex: 0)
        pinned.isPinned = true
        for value in [peer, pinned] {
            try await repository.createConversation(
                .init(id: value.id, messages: [], lastRunState: .completed, metadata: value.metadata))
        }
        let library = AssistantLibraryModel(
            store: AssistantConversationStore(conversations: [peer, pinned, conversation]))
        library.select(conversation.id)
        conversation.handle(.runState(state))
        if state == .waitingForApproval {
            let invocation = AgentToolInvocation(
                runID: UUID(), call: AgentToolCall(id: "inspect", name: "inspect", arguments: .object([:])))
            let descriptor = AgentToolDescriptor(
                name: "inspect", summary: "Inspect", inputSchema: .object([:]),
                target: .host, approvalPolicy: .ask)
            conversation.handle(
                .approvalRequested(
                    AgentApprovalRequest(invocation: invocation, descriptor: descriptor, userIntent: "Inspect")))
        }
        if compacting { conversation.beginCompaction() }
        let approvalIDs = conversation.pendingApprovals.map(\.id)
        let originalTranscript = conversation.transcript
        let originalMessages = conversation.messages.map(\.id)
        let compactionID = conversation.compactionActivity?.id

        try await operations.move(conversation, pinned: false, before: peer.id, library: library)
        #expect(library.activeConversations.map(\.id) == [conversation.id, peer.id])
        try await operations.move(conversation, pinned: true, before: pinned.id, library: library)
        #expect(library.pinnedConversations.map(\.id) == [conversation.id, pinned.id])
        #expect(library.activeConversations.map(\.id) == [peer.id])
        let pinnedStore = AssistantConversationStore()
        pinnedStore.restore(await repository.loadConversations())
        let restoredPinned = AssistantLibraryModel(store: pinnedStore)
        #expect(restoredPinned.pinnedConversations.map(\.id) == [conversation.id, pinned.id])

        try await operations.move(conversation, pinned: false, before: nil, library: library)
        #expect(library.activeConversations.map(\.id) == [peer.id, conversation.id])
        #expect(library.selectedConversation === conversation)
        #expect(conversation.runState == state)
        #expect(conversation.isCompacting == compacting)
        #expect(conversation.compactionActivity?.id == compactionID)
        #expect(conversation.pendingApprovals.map(\.id) == approvalIDs)
        #expect(conversation.transcript == originalTranscript)
        #expect(conversation.messages.map(\.id) == originalMessages)
        #expect(!conversation.isHistoryChanging)

        conversation.updatedAt = .distantFuture
        conversation.handle(.runState(.completed))
        if compacting { conversation.endCompaction() }
        #expect(library.activeConversations.map(\.id) == [peer.id, conversation.id])
        let restoredStore = AssistantConversationStore()
        restoredStore.restore(await repository.loadConversations())
        let restored = AssistantLibraryModel(store: restoredStore)
        #expect(restored.activeConversations.map(\.id) == [peer.id, conversation.id])
        #expect(restored.pinnedConversations.map(\.id) == [pinned.id])
    }

    @Test func archivedConversationCannotBeMoved() async throws {
        let (repository, conversation, operations) = try await fixture()
        let library = AssistantLibraryModel(store: AssistantConversationStore(conversations: [conversation]))
        try await operations.setArchived(true, conversation: conversation)
        #expect(library.orderUpdates(moving: conversation.id, toPinned: true, before: nil) == nil)
        try await operations.move(conversation, pinned: true, before: nil, library: library)
        #expect(!conversation.isPinned)
        #expect(library.archivedConversations.first === conversation)
        #expect(await repository.loadConversations().first?.metadata.isPinned == false)
    }

    @Test func failedMovePreservesVisibleOrderAndActiveState() async throws {
        let conversation = ConversationModel(runState: .running, sortIndex: 1)
        let peer = ConversationModel(sortIndex: 0)
        let library = AssistantLibraryModel(store: AssistantConversationStore(conversations: [peer, conversation]))
        let operations = AssistantConversationOperations(repository: RejectingConversationRepository())
        await #expect(throws: CocoaError.self) {
            try await operations.move(conversation, pinned: true, before: nil, library: library)
        }
        #expect(library.activeConversations.map(\.id) == [peer.id, conversation.id])
        #expect(library.pinnedConversations.isEmpty)
        #expect(conversation.sortIndex == 1)
        #expect(conversation.runState == .running)
        #expect(!conversation.isHistoryChanging)
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

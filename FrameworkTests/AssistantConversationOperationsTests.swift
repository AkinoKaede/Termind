import AgentKit
import Foundation
import Observation
import TermindApplication
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AssistantConversationOperationsTests {
    @Test func titleObservationIgnoresAssistantStreamingButTracksOpeningEdits() {
        let conversation = ConversationModel(messages: [ChatMessage(role: .user, text: "Opening")])
        let changed = DispatchSemaphore(value: 0)
        withObservationTracking {
            #expect(conversation.derivedTitle == "Opening")
        } onChange: {
            changed.signal()
        }
        conversation.messages.append(ChatMessage(role: .assistant, text: "Partial"))
        conversation.messages[1].text += " response"
        #expect(changed.wait(timeout: .now()) == .timedOut)
        conversation.messages[0].text = "Edited opening"
        #expect(changed.wait(timeout: .now()) == .success)
        #expect(conversation.derivedTitle == "Edited opening")
        conversation.messages = []
        #expect(conversation.derivedTitle == ConversationModel().derivedTitle)
        conversation.messages = [ChatMessage(role: .user, text: String(repeating: "a", count: 41))]
        #expect(conversation.derivedTitle == String(repeating: "a", count: 40) + "…")
    }

    @Test(arguments: [[30.0, 10, 20], [10.0, 20, 30], [20.0, 20, 30], []])
    func workAnchorsPreserveFirstQualifyingSourcePosition(timestamps: [Double]) throws {
        let messages = timestamps.map {
            ChatMessage(role: .user, text: "Message", createdAt: Date(timeIntervalSince1970: $0))
        }
        for threshold in [5.0, 10, 15, 20, 25, 30, 35] {
            let date = Date(timeIntervalSince1970: threshold)
            let run = AgentRunSummary(id: UUID(), state: .cancelled, startedAt: date, finishedAt: date)
            let conversation = ConversationModel(messages: messages, runs: [run])
            let group = try #require(conversation.workGroups.first)
            #expect(group.anchorMessageID == messages.first(where: { $0.createdAt >= date })?.id)
        }
    }

    @Test func messageActionProjectionTracksArchiveAndHistoryEdits() {
        let user = AgentTranscriptMessage(role: .user, text: "Question")
        let answer = AgentTranscriptMessage(role: .assistant, text: "Answer")
        let conversation = ConversationModel(
            messages: [
                ChatMessage(id: user.id, role: .user, text: user.text),
                ChatMessage(id: answer.id, role: .assistant, text: answer.text),
            ], transcript: [user, answer])
        #expect(conversation.messageActionAvailability.editable == [user.id])
        #expect(conversation.messageActionAvailability.forkable == [answer.id])
        conversation.archivedAt = .now
        #expect(conversation.messageActionAvailability.editable.isEmpty)
        #expect(conversation.messageActionAvailability.forkable.isEmpty)
        conversation.archivedAt = nil
        let replacement = conversation.editUserMessage(user.id, authoredText: "Revised")
        #expect(replacement != nil)
        #expect(!conversation.messageActionAvailability.editable.contains(user.id))
        #expect(conversation.messageActionAvailability.forkable.isEmpty)
        #expect(conversation.messageActionAvailability.editable == Set(conversation.transcript.map(\.id)))
    }

    @Test func emptinessUsesVisibleContentRatherThanStoredAssistantRows() {
        let hidden = ChatMessage(role: .assistant, text: "")
        let conversation = ConversationModel(messages: [hidden])
        #expect(conversation.isEmpty)
        #expect(conversation.timeline.isEmpty)
        let start = Date(timeIntervalSince1970: 100)
        let stopped = ConversationModel(
            messages: [hidden],
            runs: [AgentRunSummary(id: UUID(), state: .cancelled, startedAt: start, finishedAt: start)])
        #expect(!stopped.isEmpty)
        #expect(stopped.timeline.count == 1)
        let attachmentOnlyUser = ConversationModel(messages: [ChatMessage(role: .user, text: "")])
        #expect(!attachmentOnlyUser.isEmpty)
    }

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
    func immediateStopAndWaitPersistsCapturedCancellationWithoutCallingProviderOrTools() async throws {
        let calls = AssistantModelCalls()
        let tools = AssistantToolCalls()
        let repository = InMemoryAgentRunRepository()
        let conversation = ConversationModel()
        let promptID = UUID()
        let context = AgentTurnContextSnapshot(
            sessionContext: "captured host", skillCatalog: "captured skills",
            planContract: "captured plan", toolAvailability: ["terminal_suggest": false]
        )
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "never", summary: "Never runs", inputSchema: .object([:]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            await tools.called()
            return AgentToolResult(callID: invocation.call.id, content: "unexpected")
        }
        let runtime = AgentRuntime(
            model: CountingAssistantModel(calls: calls), tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("test") }),
            repository: repository)
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, promptID: promptID, prompt: "go",
                authoredPrompt: "Go now", permissionMode: .fullAccess,
                contextSnapshot: context),
            repository: repository)

        await conversation.stopAndWait()

        #expect(await calls.count == 0)
        #expect(await tools.count == 0)
        #expect(!conversation.isStreaming)
        #expect(conversation.runState == .cancelled)
        let stored = try #require(await repository.loadConversations().first)
        let run = try #require(stored.runs.first)
        let snapshot = try #require(await repository.snapshot(run.id))
        #expect(snapshot.state == .cancelled)
        #expect(snapshot.permissionMode == .fullAccess)
        #expect(snapshot.messages.last?.id == promptID)
        #expect(snapshot.messages.last?.text == "go")
        #expect(snapshot.messages.last?.authoredText == "Go now")
        #expect(snapshot.messages.last?.contextSnapshot == context)
        #expect(snapshot.messages.last.map { $0.createdAt <= (snapshot.finishedAt ?? .distantPast) } == true)
        #expect(conversation.messageRunIDs[promptID] == run.id)
        #expect(conversation.runSummaries[run.id]?.state == .cancelled)
    }

    @Test
    func stopThenStopAndWaitJoinsTheQueuedCancellationSave() async {
        let calls = AssistantModelCalls()
        let repository = TerminalSaveGateRepository()
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: CountingAssistantModel(calls: calls), tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("test") }),
            repository: repository)
        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "go", permissionMode: .askForApproval),
            repository: repository)

        conversation.stop()
        await repository.waitForTerminalSave()
        let join = JoinProbe()
        let waiter = Task { @MainActor in
            join.markStarted()
            await conversation.stopAndWait()
            join.markFinished()
        }
        await join.waitUntilStarted()
        #expect(!join.finished)

        await repository.releaseTerminalSaves()
        await waiter.value
        #expect(join.finished)
        #expect(await calls.count == 0)
        #expect(await repository.savedTerminalState == .cancelled)
    }

    @Test
    func queuedStopPersistsAfterConversationPresentationIsReleased() async {
        let calls = AssistantModelCalls()
        let repository = TerminalSaveGateRepository()
        weak var released: ConversationModel?
        do {
            var conversation: ConversationModel? = ConversationModel()
            released = conversation
            let runtime = AgentRuntime(
                model: CountingAssistantModel(calls: calls), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            )
            conversation?.start(
                runtime: runtime,
                request: AgentRunRequest(
                    conversationID: conversation!.id, prompt: "go",
                    permissionMode: .askForApproval),
                repository: repository
            )
            conversation?.stop()
            conversation = nil
        }

        #expect(released == nil)
        await repository.waitForTerminalSave()
        #expect(await calls.count == 0)
        await repository.releaseTerminalSaves()
        await repository.waitForTerminalSaved()
    }

    @Test
    func directStartCancelsAndPersistsTheDisplacedQueuedOwner() async {
        let oldCalls = AssistantModelCalls()
        let oldRepository = TerminalSaveGateRepository()
        let conversation = ConversationModel()
        conversation.start(
            runtime: AgentRuntime(
                model: CountingAssistantModel(calls: oldCalls), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: oldRepository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "old", permissionMode: .askForApproval),
            repository: oldRepository
        )

        let newCalls = AssistantModelCalls()
        let newRepository = InMemoryAgentRunRepository()
        conversation.start(
            runtime: AgentRuntime(
                model: HangingCountingAssistantModel(calls: newCalls), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: newRepository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "new", permissionMode: .askForApproval),
            repository: newRepository
        )

        await oldRepository.waitForTerminalSave()
        await newCalls.waitUntilCalled()
        #expect(await oldCalls.count == 0)
        #expect(conversation.runState == .running)
        await oldRepository.releaseTerminalSaves()
        await oldRepository.waitForTerminalSaved()
        #expect(await oldRepository.savedTerminalState == .cancelled)
        await conversation.stopAndWait()
    }

    @Test
    func stopAndWaitCancelsPendingApprovalAndJoinsItsTerminalSave() async {
        let tools = AssistantToolCalls()
        let repository = TerminalSaveGateRepository()
        let conversation = ConversationModel()
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "held", summary: "Held", inputSchema: .object([:]),
                target: .local, approvalPolicy: .ask
            )
        ) { invocation, _ in
            await tools.called()
            return AgentToolResult(callID: invocation.call.id, content: "unexpected")
        }
        conversation.start(
            runtime: AgentRuntime(
                model: ApprovalRequestingAssistantModel(), tools: [tool],
                approval: AgentApprovalBroker(
                    reviewer: nil,
                    manualApproval: { [weak conversation] request in
                        guard let conversation else { return .deny("gone") }
                        return await conversation.requestApproval(request)
                    }
                ),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "approve",
                permissionMode: .askForApproval),
            repository: repository
        )
        await waitUntil { conversation.pendingApproval != nil }

        let releaseTerminalSave = Task { @MainActor in
            await repository.waitForTerminalSave()
            #expect(conversation.pendingApprovals.isEmpty)
            await repository.releaseTerminalSaves()
        }
        await conversation.stopAndWait()
        await releaseTerminalSave.value

        #expect(conversation.pendingApprovals.isEmpty)
        #expect(await tools.count == 0)
        #expect(await repository.savedTerminalState == .cancelled)
        #expect(conversation.runState == .cancelled)
    }

    @Test
    func runningStopAndWaitDrainsOldPersistenceWithoutClobberingReplacement() async {
        let oldCalls = AssistantModelCalls()
        let oldRepository = TerminalSaveGateRepository()
        let conversation = ConversationModel()
        conversation.start(
            runtime: AgentRuntime(
                model: HangingCountingAssistantModel(calls: oldCalls), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: oldRepository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "old", permissionMode: .askForApproval),
            repository: oldRepository
        )
        await oldCalls.waitUntilCalled()
        await waitUntil { conversation.runSummaries.values.contains(where: { $0.state == .running }) }
        let oldRunID = try! #require(conversation.runSummaries.values.first(where: { $0.state == .running })?.id)
        let reviewInvocation = AgentToolInvocation(
            runID: oldRunID,
            call: AgentToolCall(id: "reviewed", name: "reviewed", arguments: .object([:]))
        )
        let reviewDescriptor = AgentToolDescriptor(
            name: "reviewed", summary: "Reviewed", inputSchema: .object([:]),
            target: .local, approvalPolicy: .ask
        )
        let reviewRequest = AgentApprovalRequest(
            invocation: reviewInvocation, descriptor: reviewDescriptor, userIntent: "review"
        )
        conversation.handle(.toolProposed(reviewInvocation, reviewDescriptor))
        conversation.handle(.reviewStarted(reviewRequest))
        #expect(conversation.runState == .reviewing)

        let replacementCalls = AssistantModelCalls()
        let replacementRepository = InMemoryAgentRunRepository()
        let replaceWhileOldSaveIsBlocked = Task { @MainActor in
            await oldRepository.waitForTerminalSave()
            conversation.start(
                runtime: AgentRuntime(
                    model: HangingCountingAssistantModel(calls: replacementCalls), tools: [],
                    approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                    repository: replacementRepository
                ),
                request: AgentRunRequest(
                    conversationID: conversation.id, prompt: "new", permissionMode: .askForApproval),
                repository: replacementRepository
            )
            await replacementCalls.waitUntilCalled()
            await waitUntil { conversation.runState == .running }
            await oldRepository.releaseTerminalSaves()
        }

        await conversation.stopAndWait()
        await replaceWhileOldSaveIsBlocked.value
        #expect(conversation.runState == .running)
        #expect(conversation.toolCards.first(where: { $0.id == reviewInvocation.id })?.state == .interrupted)
        #expect(await oldRepository.savedTerminalState == .cancelled)
        await conversation.stopAndWait()
    }

    @Test func deletingRemovesDurableConversation() async throws {
        let (repository, conversation, operations) = try await fixture()
        try await operations.delete(conversation)
        #expect(await repository.loadConversations().isEmpty)
    }

    @Test func invalidReplacementNeverCallsPersistence() async throws {
        let repository = TruncationSpyAgentRunRepository()
        let operations = AssistantConversationOperations(repository: repository)
        let original = AgentTranscriptMessage(role: .user, text: "Before", authoredText: "Before")
        let conversation = ConversationModel(
            messages: [ChatMessage(id: original.id, role: .user, text: original.text)],
            transcript: [original])
        let invalid = AgentTranscriptMessage(role: .assistant, text: "Not a user turn")

        #expect(
            try await operations.edit(
                conversation, messageID: original.id, replacement: invalid) == nil)
        #expect(await repository.truncationCount == 0)
        #expect(conversation.transcript == [original])
        #expect(!conversation.isHistoryChanging)
    }

    @Test func truncationFailureLeavesInMemoryHistoryUnchanged() async throws {
        let original = AgentTranscriptMessage(role: .user, text: "Before", authoredText: "Before")
        let answer = AgentTranscriptMessage(role: .assistant, text: "Existing answer")
        let conversation = ConversationModel(
            messages: [
                ChatMessage(id: original.id, role: .user, text: original.text),
                ChatMessage(id: answer.id, role: .assistant, text: answer.text),
            ],
            transcript: [original, answer])
        let originalMessages = conversation.messages
        let originalTranscript = conversation.transcript
        let replacement = AgentTranscriptMessage(role: .user, text: "After", authoredText: "After")
        let operations = AssistantConversationOperations(repository: RejectingConversationRepository())

        await #expect(throws: CocoaError.self) {
            try await operations.edit(
                conversation, messageID: original.id, replacement: replacement)
        }

        #expect(conversation.messages == originalMessages)
        #expect(conversation.transcript == originalTranscript)
        #expect(!conversation.isHistoryChanging)
    }
}

private actor TruncationSpyAgentRunRepository: AgentRunPersisting {
    private(set) var truncationCount = 0

    func save(_ snapshot: AgentRunSnapshot) {}
    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) {}
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) {
        truncationCount += 1
    }
    func createConversation(_ conversation: StoredAgentConversation) {}
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
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func called() {
        count += 1
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilCalled() async {
        guard count == 0 else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor AssistantToolCalls {
    var count = 0
    func called() { count += 1 }
}

@MainActor
private final class JoinProbe {
    private(set) var finished = false
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        started = true
        let pending = startWaiters
        startWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func markFinished() { finished = true }
}

private actor TerminalSaveGateRepository: AgentRunPersisting {
    private var terminalSaveEntered = false
    private var terminalSaveWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalSavedWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var savedTerminalState: AgentRunState?

    func save(_ snapshot: AgentRunSnapshot) async {
        guard snapshot.state.isTerminal else { return }
        terminalSaveEntered = true
        let entered = terminalSaveWaiters
        terminalSaveWaiters.removeAll()
        for waiter in entered { waiter.resume() }
        await withCheckedContinuation { terminalReleaseWaiters.append($0) }
        savedTerminalState = snapshot.state
        let saved = terminalSavedWaiters
        terminalSavedWaiters.removeAll()
        for waiter in saved { waiter.resume() }
    }

    func waitForTerminalSave() async {
        guard !terminalSaveEntered else { return }
        await withCheckedContinuation { terminalSaveWaiters.append($0) }
    }

    func releaseTerminalSaves() {
        let pending = terminalReleaseWaiters
        terminalReleaseWaiters.removeAll()
        for waiter in pending { waiter.resume() }
    }

    func waitForTerminalSaved() async {
        guard savedTerminalState == nil else { return }
        await withCheckedContinuation { terminalSavedWaiters.append($0) }
    }

    func record(_ event: AgentEvent, runID: UUID) {}
    func persistCompaction(_ record: AgentCompactionRecord, conversationID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(_ metadata: StoredAgentConversationMetadata, conversationID: UUID) {}
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) {}
    func createConversation(_ conversation: StoredAgentConversation) {}
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

private struct HangingCountingAssistantModel: AgentModelStreaming {
    let calls: AssistantModelCalls

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await calls.called()
                continuation.yield(.textDelta("working"))
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
        }
    }
}

private struct ApprovalRequestingAssistantModel: AgentModelStreaming {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.toolCallDelta(id: "held", name: "held", arguments: "{}"))
            continuation.yield(.finished(.toolCalls))
            continuation.finish()
        }
    }
}

@MainActor
private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
    while !condition() { await Task.yield() }
}

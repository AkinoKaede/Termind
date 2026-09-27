import AgentKit
import Foundation
import TermindDomain
import Testing

@testable import TermindApplication

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AssistantChatCollaborationReviewTests {
    @Test func modelCatalogUsesOnlyEnabledChatConfigurationAndReportsReadiness() async throws {
        let fixture = ChatReviewFixture()
        let disabled = ModelProvider(name: "Disabled", isEnabled: false, models: [AIModel(id: "hidden")])
        fixture.ai.upsert(disabled)
        var provider = fixture.provider
        provider.models.append(AIModel(id: "embedding", kind: .embedding))
        fixture.ai.upsert(provider)

        let unready = try await fixture.coordinator.configuredChatModels()
        #expect(Set(unready.map(\.name)) == ["source-model", "target-model"])
        #expect(unready.allSatisfy { !$0.isReady })
        fixture.ai.setSecret("test-only-secret", for: provider.credentialRef)
        let ready = try await fixture.coordinator.configuredChatModels()
        #expect(ready.allSatisfy { $0.isReady })
        #expect(ready.allSatisfy { !$0.reference.contains("test-only-secret") })
    }

    @Test func creationInheritsCapturedPolicyWithoutChangingTheManualModelOrCopyingContext() async throws {
        let fixture = ChatReviewFixture()
        fixture.source.composer.draft = "Unsent human draft"
        fixture.source.attach(ContextChip(kind: .file, label: "private.txt", content: "private attachment"))
        fixture.source.composer.armedSkillName = "source-only-skill"
        fixture.source.permissionMode = .fullAccess
        fixture.source.isPlanning = false
        let captured = fixture.sourceContext(mode: .planning, permission: .askForApproval)
        let runID = UUID()

        let result = try await fixture.coordinator.createChat(
            prompt: "Explicit task summary", model: nil, title: "Independent task", source: captured,
            sourceRunID: runID, sourceToolCallID: "create-once")
        let target = try fixture.target(from: result)
        try await waitUntil { !target.isPreparingAgentRun }

        #expect(target !== fixture.source)
        #expect(target.model == fixture.sourceModel)
        #expect(target.permissionMode == .askForApproval)
        #expect(target.isPlanning)
        #expect(fixture.ai.lastSelectedModel == fixture.targetModel)
        #expect(target.composer.draft.isEmpty)
        #expect(target.composer.attachments.isEmpty)
        #expect(target.composer.armedSkillName == nil)
        let prompt = try #require(target.transcript.first)
        #expect(prompt.text == "Explicit task summary")
        #expect(prompt.images.isEmpty && prompt.contextAttachments.isEmpty)
        #expect(prompt.authoredText == nil)
        #expect(prompt.origin?.sourceConversationID == fixture.source.id)
        #expect(prompt.origin?.sourceRunID == runID)
        #expect(prompt.origin?.sourceToolCallID == "create-once")
        #expect(prompt.contextSnapshot?.sessionContext == nil)
        #expect(!target.canEditUserMessage(prompt.id))
        #expect(fixture.source.composer.draft == "Unsent human draft")
        #expect(fixture.source.composer.attachments.count == 1)

        let restored = try #require(await fixture.repository.loadConversations().first { $0.id == target.id })
        #expect(restored.metadata.customTitle == "Independent task")
        #expect(restored.messages.first?.origin == prompt.origin)
        let retried = try await fixture.coordinator.createChat(
            prompt: "Do not send this twice", model: nil, title: nil, source: captured,
            sourceRunID: runID, sourceToolCallID: "create-once")
        #expect(try fixture.target(from: retried).id == target.id)
        #expect(fixture.store.conversations.count == 2)
        #expect(target.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func explicitUnavailableModelFailsWithoutFallbackOrCreation() async throws {
        let fixture = ChatReviewFixture()
        let unavailable = AIModelRef(modelProviderID: fixture.provider.id, modelID: "removed")
        await #expect(throws: AgentToolError.self) {
            try await fixture.coordinator.createChat(
                prompt: "task", model: AssistantChatCoordinator.reference(unavailable), title: nil,
                source: fixture.sourceContext(), sourceRunID: UUID(), sourceToolCallID: "unavailable")
        }
        #expect(fixture.store.conversations.map(\.id) == [fixture.source.id])
        #expect(await fixture.repository.loadConversations().isEmpty)
        #expect(fixture.ai.lastSelectedModel == fixture.targetModel)
    }

    @Test func idleDeliveryPreservesTargetComposerAndSettingsAndDeduplicatesRetries() async throws {
        let fixture = ChatReviewFixture()
        let target = fixture.addTarget()
        target.permissionMode = .fullAccess
        target.reasoningEffort = .high
        target.composer.draft = "Keep writing this"
        let attachment = ContextChip(kind: .pastedText, label: "Unsent attachment", content: "private draft")
        target.attach(attachment)
        target.composer.armedSkillName = "unsent-skill"
        let runID = UUID()

        let result = try await fixture.coordinator.sendToChat(
            id: target.id, message: "Incoming task", source: fixture.sourceContext(),
            sourceRunID: runID, sourceToolCallID: "send-once")
        try await waitUntil { !target.isPreparingAgentRun }
        #expect(result.objectValue?["status"]?.stringValue == "delivered")
        #expect(target.model == fixture.targetModel)
        #expect(target.permissionMode == .fullAccess)
        #expect(target.reasoningEffort == .high)
        #expect(target.composer.draft == "Keep writing this")
        #expect(target.composer.attachments.map(\.id) == [attachment.id])
        #expect(target.composer.armedSkillName == "unsent-skill")
        let incoming = try #require(target.messages.first { $0.role == .user })
        #expect(incoming.text == "Incoming task")
        #expect(incoming.contextChips.isEmpty && incoming.images.isEmpty)
        #expect(incoming.origin?.sourceConversationID == fixture.source.id)
        #expect(!target.canEditUserMessage(incoming.id))

        _ = try await fixture.coordinator.sendToChat(
            id: target.id, message: "Retry body must not be delivered", source: fixture.sourceContext(),
            sourceRunID: runID, sourceToolCallID: "send-once")
        #expect(target.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func receiptWriteFailureReleasesPreparationAndPreservesComposer() async throws {
        let fixture = ChatReviewFixture(receipts: RejectingChatReviewReceipts())
        let target = fixture.addTarget()
        target.composer.draft = "keep"
        await #expect(throws: ChatReviewWriteFailure.self) {
            try await fixture.coordinator.sendToChat(
                id: target.id, message: "Not accepted", source: fixture.sourceContext(),
                sourceRunID: UUID(), sourceToolCallID: "failed-receipt")
        }
        #expect(!target.isPreparingAgentRun)
        #expect(target.messages.isEmpty)
        #expect(target.composer.draft == "keep")
        #expect(await fixture.repository.loadConversations().isEmpty)
    }

    @Test func retryAfterTargetDeletionPreservesTheHistoricalDeliveryWithoutRecreatingTheChat() async throws {
        let fixture = ChatReviewFixture()
        let runID = UUID()
        let result = try await fixture.coordinator.createChat(
            prompt: "Delivered task", model: nil, title: "Deleted target", source: fixture.sourceContext(),
            sourceRunID: runID, sourceToolCallID: "deleted-target")
        let target = try fixture.target(from: result)
        try await waitUntil { !target.isPreparingAgentRun }
        fixture.store.remove(target.id)

        let retried = try await fixture.coordinator.createChat(
            prompt: "Do not recreate", model: nil, title: nil, source: fixture.sourceContext(),
            sourceRunID: runID, sourceToolCallID: "deleted-target")
        #expect(retried.objectValue?["status"]?.stringValue == "delivered")
        #expect(fixture.store.conversations.map(\.id) == [fixture.source.id])
        let receipt = try #require(
            try fixture.receipts.receipt(sourceRunID: runID, sourceToolCallID: "deleted-target"))
        #expect(receipt.state == .delivered)
    }

    @Test func planSenderCannotSteerAnActingRunEvenWhenItsUIToggleChanges() async throws {
        let fixture = ChatReviewFixture()
        let target = fixture.addTarget()
        fixture.startSuspendedRun(target, planning: false)
        target.isPlanning = true
        await #expect(throws: AgentToolError.self) {
            try await fixture.coordinator.sendToChat(
                id: target.id, message: "Plan only", source: fixture.sourceContext(mode: .planning),
                sourceRunID: UUID(), sourceToolCallID: "plan-to-acting")
        }
        #expect(target.pendingSteering.isEmpty)
        await target.stopAndWait()
    }

    @Test func queuedAgentDeliveryCancelledBeforeTheBoundaryNeverBecomesAHumanDraft() async throws {
        let fixture = ChatReviewFixture()
        let target = fixture.addTarget()
        fixture.startSuspendedRun(target, planning: true)
        target.isPlanning = false
        target.composer.draft = "Human draft"
        let runID = UUID()
        _ = try await fixture.coordinator.sendToChat(
            id: target.id, message: "Agent-only message", source: fixture.sourceContext(mode: .planning),
            sourceRunID: runID, sourceToolCallID: "queued")
        let pending = try #require(target.pendingSteering.first)
        #expect(pending.message.origin != nil)
        target.stop()
        await target.stopAndWait()
        #expect(target.composer.draft == "Human draft")
        #expect(target.pendingSteering.isEmpty)
        let receipt = try #require(try fixture.receipts.receipt(sourceRunID: runID, sourceToolCallID: "queued"))
        #expect(receipt.state == .undelivered)
    }

    @Test func waitDoesNotReportAnOldCompletedRunWhileTheNextRunIsPreparing() async throws {
        let fixture = ChatReviewFixture()
        let target = fixture.addTarget()
        target.handle(.runState(.completed))
        let preparationID = UUID()
        let didPrepare = target.beginAgentPreparation(id: preparationID, cancellation: { Task {} })
        #expect(didPrepare)
        let waiting = try await fixture.coordinator.waitForChats(
            ids: [target.id], timeoutMilliseconds: 0, source: fixture.sourceContext(),
            untilUserInterjects: {})
        #expect(waiting.objectValue?["timed_out"]?.boolValue == true)
        #expect(waiting.objectValue?["chats"]?.arrayValue?.first?.objectValue?["status"]?.stringValue == "preparing")
        target.finishAgentPreparation(id: preparationID)
        let completed = try await fixture.coordinator.waitForChats(
            ids: [target.id], timeoutMilliseconds: 0, source: fixture.sourceContext(),
            untilUserInterjects: {})
        #expect(completed.objectValue?["timed_out"]?.boolValue == false)
    }

    @Test func chatListingExcludesArchivesAndReadReturnsBoundedVisibleText() async throws {
        let fixture = ChatReviewFixture()
        for index in 0..<24 {
            let target = fixture.addTarget()
            target.customTitle = "Task \(index)"
        }
        let archived = fixture.addTarget()
        archived.archivedAt = .now
        let result = try await fixture.coordinator.listChats(cursor: nil, includeArchived: false)
        let rows = try #require(result.objectValue?["chats"]?.arrayValue)
        #expect(rows.count == 20)
        #expect(rows.allSatisfy { $0.objectValue?["archived"]?.boolValue == false })
        #expect(rows.allSatisfy { $0.objectValue?["messages"] == nil })
        let next = try #require(result.objectValue?["next_cursor"]?.stringValue)
        let second = try await fixture.coordinator.listChats(cursor: next, includeArchived: false)
        #expect(second.objectValue?["chats"]?.arrayValue?.count == 5)

        let target = fixture.addTarget()
        target.messages = [ChatMessage(role: .assistant, text: String(repeating: "x", count: 20_000))]
        let read = try await fixture.coordinator.readChat(id: target.id, cursor: nil)
        #expect(read.objectValue?["truncated"]?.boolValue == true)
        let text = try #require(read.objectValue?["messages"]?.arrayValue?.first?.objectValue?["text"]?.stringValue)
        #expect(text.count == 8_000)
    }

    @Test func listingBatchesMixedCreatorRelationsOncePerPage() async throws {
        let collaborationStore = CountingChatReviewStore()
        let fixture = ChatReviewFixture(receipts: collaborationStore)
        fixture.source.updatedAt = Date(timeIntervalSince1970: 0)
        var targets: [ConversationModel] = []
        for index in 0..<21 {
            let target = fixture.addTarget()
            target.customTitle = "Target \(index)"
            target.updatedAt = Date(timeIntervalSince1970: Double(10_000 - index))
            targets.append(target)
        }
        let firstRelation = AssistantChatCreationRelation(
            conversationID: targets[0].id,
            sourceConversationID: fixture.source.id,
            sourceRunID: UUID(),
            sourceToolCallID: "first-page")
        let secondRelation = AssistantChatCreationRelation(
            conversationID: targets[20].id,
            sourceConversationID: fixture.source.id,
            sourceRunID: UUID(),
            sourceToolCallID: "second-page")
        try collaborationStore.save(firstRelation)
        try collaborationStore.save(secondRelation)
        let firstPageIDs = Set(targets.prefix(20).map(\.id))
        let secondPageIDs = Set([targets[20].id, fixture.source.id])

        let first = try await fixture.coordinator.listChats(cursor: nil, includeArchived: false)
        let firstRows = try #require(first.objectValue?["chats"]?.arrayValue)
        #expect(collaborationStore.relationReads == [firstPageIDs])
        #expect(try creator(in: firstRows, conversationID: targets[0].id)["kind"] == .string("agent"))
        #expect(try creator(in: firstRows, conversationID: targets[1].id) == ["kind": .string("user")])

        let cursor = try #require(first.objectValue?["next_cursor"]?.stringValue)
        let second = try await fixture.coordinator.listChats(cursor: cursor, includeArchived: false)
        let secondRows = try #require(second.objectValue?["chats"]?.arrayValue)
        #expect(collaborationStore.relationReads == [firstPageIDs, secondPageIDs])
        let secondCreator = try creator(in: secondRows, conversationID: targets[20].id)
        #expect(secondCreator["kind"] == .string("agent"))
        #expect(secondCreator["chat_id"] == .string(fixture.source.id.uuidString))
        #expect(secondCreator["title"] == .string("Source"))
        #expect(try creator(in: secondRows, conversationID: fixture.source.id) == ["kind": .string("user")])
    }

    @Test func creatorKeepsCreationAuthorityThroughLaterDeliveryRenameAndSourceDeletion() async throws {
        let fixture = ChatReviewFixture()
        let creationRunID = UUID()
        let created = try await fixture.coordinator.createChat(
            prompt: "Created task", model: nil, title: "Created target",
            source: fixture.sourceContext(), sourceRunID: creationRunID,
            sourceToolCallID: "create-target")
        #expect(created.objectValue?["creator"] == nil)
        let target = try fixture.target(from: created)
        try await waitUntil { !target.isPreparingAgentRun }

        let laterSourceID = UUID()
        let later = try await fixture.coordinator.sendToChat(
            id: target.id, message: "Later agent message",
            source: AgentChatSourceContext(
                conversationID: laterSourceID,
                title: "Later source",
                modelReference: AssistantChatCoordinator.reference(fixture.sourceModel),
                permissionMode: .askForApproval,
                mode: .acting),
            sourceRunID: UUID(), sourceToolCallID: "later-send")
        #expect(later.objectValue?["creator"] == nil)
        try await waitUntil { !target.isPreparingAgentRun }
        #expect(target.messages.compactMap(\.origin).count == 2)

        var rows = try await listRows(fixture)
        var creatorInfo = try creator(in: rows, conversationID: target.id)
        #expect(creatorInfo["chat_id"] == .string(fixture.source.id.uuidString))
        #expect(creatorInfo["title"] == .string("Source"))

        fixture.source.customTitle = "Renamed source"
        rows = try await listRows(fixture)
        creatorInfo = try creator(in: rows, conversationID: target.id)
        #expect(creatorInfo["title"] == .string("Renamed source"))

        fixture.store.remove(fixture.source.id)
        rows = try await listRows(fixture)
        creatorInfo = try creator(in: rows, conversationID: target.id)
        #expect(creatorInfo["chat_id"] == .string(fixture.source.id.uuidString))
        #expect(creatorInfo["title"] == .string("Source"))
    }

    @Test func creatorUsesNullWithoutAnExactSavedTitleAndManualForkRemainsUserCreated() async throws {
        let fixture = ChatReviewFixture()
        let missingSourceID = UUID()
        let creationRunID = UUID()
        let target = fixture.addTarget()
        target.messages = [
            ChatMessage(
                role: .user,
                text: "Wrong run",
                origin: AgentMessageOrigin(
                    sourceConversationID: missingSourceID,
                    sourceRunID: UUID(),
                    sourceToolCallID: "create-without-title",
                    sourceTitle: "Wrong run title")),
            ChatMessage(
                role: .user,
                text: "Wrong tool call",
                origin: AgentMessageOrigin(
                    sourceConversationID: missingSourceID,
                    sourceRunID: creationRunID,
                    sourceToolCallID: "wrong-tool-call",
                    sourceTitle: "Wrong tool title")),
            ChatMessage(
                role: .user,
                text: "Created without a saved title",
                origin: AgentMessageOrigin(
                    sourceConversationID: missingSourceID,
                    sourceRunID: creationRunID,
                    sourceToolCallID: "create-without-title")),
        ]
        try fixture.receipts.save(
            AssistantChatCreationRelation(
                conversationID: target.id,
                sourceConversationID: missingSourceID,
                sourceRunID: creationRunID,
                sourceToolCallID: "create-without-title"))

        let compactedSourceID = UUID()
        let compactedRunID = UUID()
        let displayOnlyTarget = fixture.addTarget()
        displayOnlyTarget.messages = [
            ChatMessage(
                role: .user,
                text: "Created before compaction",
                origin: AgentMessageOrigin(
                    sourceConversationID: compactedSourceID,
                    sourceRunID: compactedRunID,
                    sourceToolCallID: "compacted-creation",
                    sourceTitle: "Compacted source"))
        ]
        #expect(displayOnlyTarget.transcript.isEmpty)
        try fixture.receipts.save(
            AssistantChatCreationRelation(
                conversationID: displayOnlyTarget.id,
                sourceConversationID: compactedSourceID,
                sourceRunID: compactedRunID,
                sourceToolCallID: "compacted-creation"))

        let copiedOrigin = AgentMessageOrigin(
            sourceConversationID: UUID(), sourceRunID: UUID(),
            sourceToolCallID: "copied", sourceTitle: "Copied source")
        let manualSource = ConversationModel()
        let incoming = manualSource.composeIncomingAgentTurn("Copied task", origin: copiedOrigin)
        _ = manualSource.appendIncomingAgentTurnContent(incoming)
        let answer = AgentTranscriptMessage(role: .assistant, text: "Answer")
        manualSource.handle(.messageFinished(answer))
        let fork = try #require(manualSource.forked(throughAssistantMessage: answer.id))
        fixture.store.insert(fork)

        let rows = try await listRows(fixture)
        let targetCreator = try creator(in: rows, conversationID: target.id)
        #expect(targetCreator["kind"] == .string("agent"))
        #expect(targetCreator["chat_id"] == .string(missingSourceID.uuidString))
        #expect(targetCreator["title"] == .null)
        #expect(
            try creator(in: rows, conversationID: displayOnlyTarget.id)["title"]
                == .string("Compacted source"))
        #expect(try creator(in: rows, conversationID: fork.id) == ["kind": .string("user")])
        #expect(fork.messages.first?.origin == copiedOrigin)
    }

    @Test func relationReadFailurePropagatesFromListChats() async {
        let fixture = ChatReviewFixture(receipts: RejectingChatReviewRelationReads())

        await #expect(throws: ChatReviewReadFailure.self) {
            try await fixture.coordinator.listChats(cursor: nil, includeArchived: false)
        }
    }

    private func listRows(_ fixture: ChatReviewFixture) async throws -> [AgentJSONValue] {
        let result = try await fixture.coordinator.listChats(
            cursor: nil,
            includeArchived: false)
        return try #require(result.objectValue?["chats"]?.arrayValue)
    }

    private func creator(
        in rows: [AgentJSONValue], conversationID: UUID
    ) throws -> [String: AgentJSONValue] {
        let row = try #require(
            rows.first { $0.objectValue?["chat_id"] == .string(conversationID.uuidString) })
        return try #require(row.objectValue?["creator"]?.objectValue)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw ChatReviewTimeout() }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

@MainActor
private final class ChatReviewFixture {
    let provider: ModelProvider
    let ai: AIConfigurationModel
    let source = ConversationModel()
    let store: AssistantConversationStore
    let repository = InMemoryAgentRunRepository()
    let receipts: any AssistantChatCollaborationStoring
    let controller: AssistantExecutionController
    let coordinator: AssistantChatCoordinator
    let sourceModel: AIModelRef
    let targetModel: AIModelRef

    init(receipts: any AssistantChatCollaborationStoring = InMemoryAssistantChatCollaborationStore()) {
        let provider = ModelProvider(
            name: "Configured", inferenceURL: "https://example.invalid/v1/chat/completions",
            credentialRef: "chat-review-key", models: [AIModel(id: "source-model"), AIModel(id: "target-model")])
        self.provider = provider
        sourceModel = AIModelRef(modelProviderID: provider.id, modelID: "source-model")
        targetModel = AIModelRef(modelProviderID: provider.id, modelID: "target-model")
        ai = AIConfigurationModel(modelProviders: [provider], lastSelectedModel: targetModel, persistsSecrets: false)
        let selections = AssistantModelSelectionController(ai: ai, store: InMemoryAssistantModelSelectionStore())
        source.model = sourceModel
        source.customTitle = "Source"
        store = AssistantConversationStore(conversations: [source])
        self.receipts = receipts
        let controller = AssistantExecutionController(
            ai: ai, skills: SkillLibraryModel(), repository: repository, modelSelections: selections,
            authorize: { true }, makeRegistry: { _, _, _, _, _, _, _ in AgentToolRegistry([]) },
            title: { _ in "Generated" })
        self.controller = controller
        coordinator = AssistantChatCoordinator(
            conversations: store, ai: ai, modelSelections: selections, collaborationStore: receipts,
            prepareDelivery: { text, origin, target in
                controller.prepareIncomingAgentMessage(text, origin: origin, in: target)
            },
            persistDelivery: { prepared, target in
                try await controller.persistPreparedAgentDelivery(prepared, in: target)
            },
            startDelivery: { prepared, target in controller.startPreparedAgentDelivery(prepared, in: target) },
            cancelDelivery: { prepared, target in await controller.cancelPreparedAgentDelivery(prepared, in: target) })
    }

    func sourceContext(
        mode: AgentRunMode = .acting, permission: AgentPermissionMode = .askForApproval
    ) -> AgentChatSourceContext {
        AgentChatSourceContext(
            conversationID: source.id, title: source.derivedTitle,
            modelReference: AssistantChatCoordinator.reference(sourceModel), permissionMode: permission, mode: mode)
    }

    func addTarget() -> ConversationModel {
        let target = ConversationModel()
        target.model = targetModel
        store.insert(target)
        return target
    }

    func target(from result: AgentJSONValue) throws -> ConversationModel {
        let raw = try #require(result.objectValue?["chat_id"]?.stringValue)
        let id = try #require(UUID(uuidString: raw))
        return try #require(store.conversation(id: id))
    }

    func startSuspendedRun(_ target: ConversationModel, planning: Bool) {
        target.start(
            runtime: AgentRuntime(
                model: SuspendedChatReviewModel(), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }), repository: repository),
            request: AgentRunRequest(
                conversationID: target.id, prompt: "Existing run",
                permissionMode: .askForApproval, isPlanning: planning), repository: repository)
    }
}

private struct SuspendedChatReviewModel: AgentModelStreaming {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { _ in }
    }
}

private struct ChatReviewWriteFailure: Error {}
private struct ChatReviewReadFailure: Error {}
private struct ChatReviewTimeout: Error {}

@MainActor
private final class CountingChatReviewStore: AssistantChatCollaborationStoring {
    private let base = InMemoryAssistantChatCollaborationStore()
    private(set) var relationReads: [Set<UUID>] = []

    var confirmsDeliveryDuringMessagePersistence: Bool {
        base.confirmsDeliveryDuringMessagePersistence
    }

    func receipt(sourceRunID: UUID, sourceToolCallID: String) throws -> AssistantChatDeliveryReceipt? {
        try base.receipt(sourceRunID: sourceRunID, sourceToolCallID: sourceToolCallID)
    }

    func save(_ receipt: AssistantChatDeliveryReceipt) throws {
        try base.save(receipt)
    }

    func updateReceipt(
        messageID: UUID, state: AgentMessageDeliveryState, failure: String?
    ) throws {
        try base.updateReceipt(messageID: messageID, state: state, failure: failure)
    }

    func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt] {
        try base.receipts(targetConversationID: targetConversationID)
    }

    func save(_ relation: AssistantChatCreationRelation) throws {
        try base.save(relation)
    }

    func creationRelations(
        conversationIDs: Set<UUID>
    ) throws -> [UUID: AssistantChatCreationRelation] {
        relationReads.append(conversationIDs)
        return try base.creationRelations(conversationIDs: conversationIDs)
    }

    func deleteRelation(conversationID: UUID) throws {
        try base.deleteRelation(conversationID: conversationID)
    }
}

@MainActor
private struct RejectingChatReviewReceipts: AssistantChatCollaborationStoring {
    let confirmsDeliveryDuringMessagePersistence = false
    func receipt(sourceRunID: UUID, sourceToolCallID: String) throws -> AssistantChatDeliveryReceipt? { nil }
    func save(_ receipt: AssistantChatDeliveryReceipt) throws { throw ChatReviewWriteFailure() }
    func updateReceipt(messageID: UUID, state: AgentMessageDeliveryState, failure: String?) throws {}
    func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt] { [] }
    func save(_ relation: AssistantChatCreationRelation) throws { throw ChatReviewWriteFailure() }
    func creationRelations(
        conversationIDs: Set<UUID>
    ) throws -> [UUID: AssistantChatCreationRelation] { [:] }
    func deleteRelation(conversationID: UUID) throws {}
}

@MainActor
private struct RejectingChatReviewRelationReads: AssistantChatCollaborationStoring {
    let confirmsDeliveryDuringMessagePersistence = false
    func receipt(sourceRunID: UUID, sourceToolCallID: String) throws -> AssistantChatDeliveryReceipt? { nil }
    func save(_ receipt: AssistantChatDeliveryReceipt) throws {}
    func updateReceipt(messageID: UUID, state: AgentMessageDeliveryState, failure: String?) throws {}
    func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt] { [] }
    func save(_ relation: AssistantChatCreationRelation) throws {}
    func creationRelations(
        conversationIDs: Set<UUID>
    ) throws -> [UUID: AssistantChatCreationRelation] { throw ChatReviewReadFailure() }
    func deleteRelation(conversationID: UUID) throws {}
}

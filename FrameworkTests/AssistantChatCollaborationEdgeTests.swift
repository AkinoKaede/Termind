// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindDomain
import Testing

@testable import TermindApplication

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AssistantChatCollaborationEdgeTests {
    @Test
    func metadataFailureAfterDurablePromptStillAcceptsCreatedChat() async throws {
        let repository = MetadataRejectingAgentRunRepository()
        let fixture = ChatCollaborationEdgeFixture(repository: repository)

        let result = try await fixture.coordinator.createChat(
            prompt: "Durable delegated task", model: nil, title: "Delegated",
            source: fixture.sourceContext(), sourceRunID: UUID(),
            sourceToolCallID: "metadata-failure")

        let id = try #require(
            result.objectValue?["chat_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        #expect(result.objectValue?["status"]?.stringValue == "accepted")
        #expect(fixture.store.conversation(id: id) != nil)
        let stored = try #require(try await repository.loadConversations().first { $0.id == id })
        #expect(stored.messages.map(\.text) == ["Durable delegated task"])
        #expect(stored.messages.first?.origin?.sourceConversationID == fixture.source.id)
    }

    @Test
    func nonzeroWaitTimesOutAndCancelsItsInterjectionWaiter() async throws {
        let fixture = ChatCollaborationEdgeFixture()
        let target = fixture.addTarget()
        let signal = AgentInterjectionSignal()

        let result = try await fixture.coordinator.waitForChats(
            ids: [target.id], timeoutMilliseconds: 20, source: fixture.sourceContext(),
            untilUserInterjects: { await signal.wait() })

        #expect(result.objectValue?["timed_out"]?.boolValue == true)
        #expect(result.objectValue?["interrupted"]?.boolValue == false)
    }

    @Test
    func userInterjectionEndsNonzeroWaitWithoutChangingTargetState() async throws {
        let fixture = ChatCollaborationEdgeFixture()
        let target = fixture.addTarget()
        target.handle(.runState(.running))
        let signal = AgentInterjectionSignal()
        let waiting = Task { @MainActor in
            try await fixture.coordinator.waitForChats(
                ids: [target.id], timeoutMilliseconds: 60_000,
                source: fixture.sourceContext(), untilUserInterjects: { await signal.wait() })
        }

        try await Task.sleep(for: .milliseconds(10))
        signal.arm()
        let result = try await waiting.value

        #expect(result.objectValue?["timed_out"]?.boolValue == false)
        #expect(result.objectValue?["interrupted"]?.boolValue == true)
        #expect(target.runState == .running)
    }

    @Test
    func targetCompletionEndsNonzeroWaitAndCancelsInterjectionWaiter() async throws {
        let fixture = ChatCollaborationEdgeFixture()
        let target = fixture.addTarget()
        target.handle(.runState(.running))
        let signal = AgentInterjectionSignal()
        let waiting = Task { @MainActor in
            try await fixture.coordinator.waitForChats(
                ids: [target.id], timeoutMilliseconds: 60_000,
                source: fixture.sourceContext(), untilUserInterjects: { await signal.wait() })
        }

        try await Task.sleep(for: .milliseconds(10))
        target.handle(.runState(.completed))
        let result = try await waiting.value

        #expect(result.objectValue?["timed_out"]?.boolValue == false)
        #expect(result.objectValue?["interrupted"]?.boolValue == false)
    }

    @Test
    func cancellingNonzeroWaitDoesNotRemainRegisteredUntilItsDeadline() async throws {
        let fixture = ChatCollaborationEdgeFixture()
        let target = fixture.addTarget()
        target.handle(.runState(.running))
        let signal = AgentInterjectionSignal()
        let clock = ContinuousClock()
        let waiting = Task { @MainActor in
            try await fixture.coordinator.waitForChats(
                ids: [target.id], timeoutMilliseconds: 60_000,
                source: fixture.sourceContext(), untilUserInterjects: { await signal.wait() })
        }
        let cleanup = Task {
            try? await Task.sleep(for: .milliseconds(200))
            signal.arm()
        }

        await Task.yield()
        let start = clock.now
        waiting.cancel()
        _ = try await waiting.value
        let returnedBeforeCleanup = clock.now - start < .milliseconds(100)
        signal.arm()
        cleanup.cancel()

        #expect(returnedBeforeCleanup)
    }
}

@MainActor
private final class ChatCollaborationEdgeFixture {
    let source = ConversationModel()
    let store: AssistantConversationStore
    let receipts = InMemoryAssistantChatCollaborationStore()
    let coordinator: AssistantChatCoordinator
    private let sourceModel: AIModelRef
    private let targetModel: AIModelRef

    init(repository: any AgentRunPersisting = InMemoryAgentRunRepository()) {
        let provider = ModelProvider(
            name: "Configured", inferenceURL: "https://example.invalid/v1/chat/completions",
            credentialRef: "chat-edge-key",
            models: [AIModel(id: "source-model"), AIModel(id: "target-model")])
        sourceModel = AIModelRef(modelProviderID: provider.id, modelID: "source-model")
        targetModel = AIModelRef(modelProviderID: provider.id, modelID: "target-model")
        let ai = AIConfigurationModel(
            modelProviders: [provider], lastSelectedModel: targetModel, persistsSecrets: false)
        ai.setSecret("test-only", for: provider.credentialRef)
        let selections = AssistantModelSelectionController(
            ai: ai, store: InMemoryAssistantModelSelectionStore())
        source.model = sourceModel
        source.customTitle = "Source"
        store = AssistantConversationStore(conversations: [source])
        let controller = AssistantExecutionController(
            ai: ai, skills: SkillLibraryModel(), repository: repository,
            modelSelections: selections, authorize: { true },
            makeRegistry: { _, _, _, _, _, _, _ in AgentToolRegistry([]) },
            title: { _ in "Generated" })
        coordinator = AssistantChatCoordinator(
            conversations: store, ai: ai, modelSelections: selections,
            collaborationStore: receipts,
            prepareDelivery: { text, origin, target in
                controller.prepareIncomingAgentMessage(text, origin: origin, in: target)
            },
            persistDelivery: { prepared, target in
                try await controller.persistPreparedAgentDelivery(prepared, in: target)
            },
            startDelivery: { _, _ in },
            cancelDelivery: { prepared, target in
                await controller.cancelPreparedAgentDelivery(prepared, in: target)
            })
    }

    func sourceContext() -> AgentChatSourceContext {
        AgentChatSourceContext(
            conversationID: source.id, title: source.derivedTitle,
            modelReference: AssistantChatCoordinator.reference(sourceModel),
            permissionMode: .askForApproval, mode: .acting)
    }

    func addTarget() -> ConversationModel {
        let target = ConversationModel()
        target.model = targetModel
        store.insert(target)
        return target
    }
}

private actor MetadataRejectingAgentRunRepository: AgentRunPersisting {
    private let base = InMemoryAgentRunRepository()

    func save(_ snapshot: AgentRunSnapshot) async throws { await base.save(snapshot) }
    func record(_ event: AgentEvent, runID: UUID) async throws {
        await base.record(event, runID: runID)
    }
    func persistCompaction(
        _ record: AgentCompactionRecord, conversationID: UUID
    ) async throws {
        try await base.persistCompaction(record, conversationID: conversationID)
    }
    func loadConversations() async throws -> [StoredAgentConversation] {
        await base.loadConversations()
    }
    func deleteConversation(_ id: UUID) async throws {
        await base.deleteConversation(id)
    }
    func setTitle(_ title: String, conversationID: UUID) async throws {
        await base.setTitle(title, conversationID: conversationID)
    }
    func setConversationMetadata(
        _ metadata: StoredAgentConversationMetadata, conversationID: UUID
    ) async throws {
        throw CocoaError(.fileWriteNoPermission)
    }
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) async throws {
        try await base.reorderConversations(updates)
    }
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) async throws {
        try await base.truncateConversation(
            id, fromUserMessageID: messageID, replacingWith: message)
    }
    func createConversation(_ conversation: StoredAgentConversation) async throws {
        try await base.createConversation(conversation)
    }
}

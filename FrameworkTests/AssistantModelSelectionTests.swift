// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import Testing

@Suite @MainActor
struct AssistantModelSelectionTests {
    @Test func newDraftKeepsItsInitialModelWhenRolesOrLastChoiceChange() {
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let ai = AIConfigurationModel(modelProviders: [provider], lastSelectedModel: first)
        let controller = AssistantModelSelectionController(ai: ai, store: InMemoryAssistantModelSelectionStore())
        let library = AssistantLibraryModel()
        library.modelSelections = controller

        #expect(library.draftConversation.model == first)
        ai.select(second)
        #expect(library.draftConversation.model == first)
        #expect(library.resetDraftConversation().model == second)

        ai.assign(first, to: .chat)
        #expect(library.resetDraftConversation().model == first)
        ai.assign(nil, to: .chat)
        #expect(library.resetDraftConversation().model == second)
    }

    @Test func oldChatIsBackfilledAndNeverFollowsLaterRoleChanges() throws {
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let ai = AIConfigurationModel(modelProviders: [provider], lastSelectedModel: first)
        let persistence = InMemoryAssistantModelSelectionStore()
        let controller = AssistantModelSelectionController(ai: ai, store: persistence)
        let stored = StoredAgentConversation(id: UUID(), messages: [], lastRunState: .completed)

        let selections = try controller.selectionsForRestore([stored])
        let conversations = AssistantConversationStore()
        conversations.restore([stored], modelSelections: selections)
        let restored = try #require(conversations.conversation(id: stored.id))
        #expect(restored.model == first)

        ai.assign(second, to: .chat)
        #expect(restored.model == first)
        #expect(try persistence.load()[stored.id] == first)
        #expect(try controller.selectionsForRestore([stored])[stored.id] == first)
    }

    @Test func unavailableChoiceFallsBackOnceAndPersistsTheReplacement() throws {
        let oldProvider = ModelProvider(name: "Old", models: [AIModel(id: "old")])
        let newProvider = ModelProvider(name: "New", models: [AIModel(id: "new")])
        let old = AIModelRef(modelProviderID: oldProvider.id, modelID: "old")
        let replacement = AIModelRef(modelProviderID: newProvider.id, modelID: "new")
        let ai = AIConfigurationModel(
            modelProviders: [oldProvider, newProvider], lastSelectedModel: replacement)
        let persistence = InMemoryAssistantModelSelectionStore()
        let controller = AssistantModelSelectionController(ai: ai, store: persistence)
        let conversation = ConversationModel()
        conversation.model = old
        try persistence.save(old, for: conversation.id)
        ai.didChange = { try? controller.repairUnavailable(in: [conversation]) }

        ai.setModelProviderEnabled(false, for: oldProvider.id)
        #expect(conversation.model == replacement)
        #expect(try persistence.load()[conversation.id] == replacement)
        #expect(try controller.prepareForSend(conversation) == replacement)

        ai.setModelProviderEnabled(true, for: oldProvider.id)
        #expect(try controller.prepareForSend(conversation) == replacement)
    }

    @Test func aModelChangedToEmbeddingFallsBackToAnAvailableChatModel() throws {
        let oldProvider = ModelProvider(name: "Old", models: [AIModel(id: "old")])
        let newProvider = ModelProvider(name: "New", models: [AIModel(id: "new")])
        let old = AIModelRef(modelProviderID: oldProvider.id, modelID: "old")
        let replacement = AIModelRef(modelProviderID: newProvider.id, modelID: "new")
        let ai = AIConfigurationModel(modelProviders: [oldProvider, newProvider], lastSelectedModel: old)
        let persistence = InMemoryAssistantModelSelectionStore()
        let controller = AssistantModelSelectionController(ai: ai, store: persistence)
        let conversation = ConversationModel()
        conversation.model = old
        try persistence.save(old, for: conversation.id)

        var changedProvider = oldProvider
        changedProvider.models = [AIModel(id: "old", kind: .embedding)]
        ai.upsert(changedProvider)
        try controller.repairUnavailable(in: [conversation])

        #expect(ai.resolve(.chat)?.model.id == "new")
        #expect(conversation.model == replacement)
        #expect(try persistence.load()[conversation.id] == replacement)
    }

    @Test func failedSaveLeavesTheChatAndAutomaticChoiceUnchanged() {
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let ai = AIConfigurationModel(modelProviders: [provider], lastSelectedModel: first)
        let controller = AssistantModelSelectionController(ai: ai, store: FailingSelectionStore())
        let conversation = ConversationModel(
            transcript: [AgentTranscriptMessage(role: .user, text: "Existing chat")])
        conversation.model = first

        #expect(throws: SelectionWriteFailure.self) {
            try controller.select(second, for: conversation)
        }
        #expect(conversation.model == first)
        #expect(ai.lastSelectedModel == first)
    }

    @Test func modelSlashCommandPersistsTheChoiceThroughItsSelectionCallback() throws {
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let persistence = InMemoryAssistantModelSelectionStore()
        let controller = AssistantModelSelectionController(ai: ai, store: persistence)
        let conversation = ConversationModel(
            transcript: [AgentTranscriptMessage(role: .user, text: "Existing chat")])
        conversation.model = first
        let context = ChatSlashCommandContext(
            platform: .desktop, conversation: conversation, configuration: ai,
            skills: SkillLibraryModel(), compact: { _ in }, send: {},
            selectModel: { model in
                do {
                    try controller.select(model, for: conversation)
                    return true
                } catch { return false }
            })
        let argument = ChatSlashCommand.argumentID(scope: provider.id.uuidString.lowercased(), value: "second")

        #expect(ChatSlashCommandRegistry.standard().perform(draft: "/model \(argument)", in: context))
        #expect(conversation.model == second)
        #expect(try persistence.load()[conversation.id] == second)
    }
}

private struct SelectionWriteFailure: Error {}

@MainActor
private struct FailingSelectionStore: AssistantModelSelectionStoring {
    func load() throws -> [UUID: AIModelRef] { [:] }
    func save(_ model: AIModelRef, for conversationID: UUID) throws { throw SelectionWriteFailure() }
}

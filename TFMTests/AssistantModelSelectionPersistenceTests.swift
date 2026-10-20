// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindPersistence
import Testing

@Suite @MainActor
struct AssistantModelSelectionPersistenceTests {
    @Test func firstSendAndLaterManualChoiceRestoreForTheSameChat() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let selections = SwiftDataAssistantModelSelectionStore(context: container.mainContext)
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let controller = AssistantModelSelectionController(ai: ai, store: selections)
        let chat = ConversationModel()
        controller.seed(chat)
        #expect(chat.model == first)
        #expect(try controller.prepareForSend(chat) == first)
        try await repository.save(
            AgentRunSnapshot(
                conversationID: chat.id, state: .completed, permissionMode: .askForApproval,
                messages: [AgentTranscriptMessage(role: .user, text: "Hello")]))

        let loaded = try await repository.loadConversations()
        let restoredStore = AssistantConversationStore()
        restoredStore.restore(loaded, modelSelections: try controller.selectionsForRestore(loaded))
        let reopened = try #require(restoredStore.conversation(id: chat.id))
        #expect(reopened.model == first)
        try controller.select(second, for: reopened)
        #expect(try selections.load()[chat.id] == second)

        let reopenedAgain = AssistantConversationStore()
        reopenedAgain.restore(loaded, modelSelections: try controller.selectionsForRestore(loaded))
        #expect(reopenedAgain.conversation(id: chat.id)?.model == second)
    }

    @Test func v38ConversationGetsOneDurableModelAndDeletionRemovesIt() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TermindChatModelMigration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Termind.store")
        let oldSchema = Schema(versionedSchema: TermindSchemaV38.self)
        let id = UUID()
        var oldContainer: ModelContainer? = try ModelContainer(
            for: oldSchema,
            configurations: [localModelConfiguration("Old", schema: oldSchema, url: url)])
        oldContainer?.mainContext.insert(PersistentAgentConversation(id: id, title: "Old Chat"))
        try oldContainer?.mainContext.save()
        oldContainer = nil

        let container = try TermindPersistence.makeContainer(url: url)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let selections = SwiftDataAssistantModelSelectionStore(context: container.mainContext)
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "current")])
        let model = AIModelRef(modelProviderID: provider.id, modelID: "current")
        let ai = AIConfigurationModel(modelProviders: [provider])
        let controller = AssistantModelSelectionController(ai: ai, store: selections)
        let oldChats = try await repository.loadConversations()

        #expect(try controller.selectionsForRestore(oldChats)[id] == model)
        #expect(try selections.load()[id] == model)
        ai.assign(nil, to: .chat)
        #expect(try controller.selectionsForRestore(oldChats)[id] == model)

        try await repository.deleteConversation(id)
        #expect(try selections.load()[id] == nil)
    }

    @Test func forkKeepsTheSourceModelInItsOwnDurableRecord() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let selections = SwiftDataAssistantModelSelectionStore(context: container.mainContext)
        let provider = ModelProvider(name: "Models", models: [AIModel(id: "first"), AIModel(id: "second")])
        let first = AIModelRef(modelProviderID: provider.id, modelID: "first")
        let second = AIModelRef(modelProviderID: provider.id, modelID: "second")
        let controller = AssistantModelSelectionController(
            ai: AIConfigurationModel(modelProviders: [provider]), store: selections)
        let user = AgentTranscriptMessage(role: .user, text: "Hello")
        let answer = AgentTranscriptMessage(role: .assistant, text: "World")
        let source = ConversationModel(transcript: [user, answer], runState: .completed)
        source.model = second
        try selections.save(second, for: source.id)
        let operations = AssistantConversationOperations(repository: repository, modelSelections: controller)

        let fork = try #require(try await operations.fork(source, at: answer.id, title: "Fork"))
        #expect(fork.model == second)
        #expect(try selections.load()[fork.id] == second)
        #expect(try selections.load()[source.id] == second)
        #expect(try await repository.loadConversations().contains { $0.id == fork.id })

        try controller.select(first, for: source)
        #expect(try selections.load()[source.id] == first)
        #expect(try selections.load()[fork.id] == second)
    }
}

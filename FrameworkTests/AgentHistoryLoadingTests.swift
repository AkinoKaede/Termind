// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData
import TermindPersistence
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AgentHistoryLoadingTests {
    @Test func loadingSavedHistoryAllowsMainActorWorkAndKeepsRunLocalToolResults() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        var expectedMessages: [UUID: [UUID]] = [:]
        var expectedOutput: [UUID: String] = [:]
        let date = Date(timeIntervalSince1970: 1_000)
        for conversationIndex in 0..<12 {
            let conversationID = UUID()
            context.insert(PersistentAgentConversation(id: conversationID, title: "Conversation \(conversationIndex)"))
            for runIndex in 0..<12 {
                // Providers can reuse a call ID in different runs. Both recovery
                // and tool cards must still use the owning run's durable output.
                let call = AgentToolCall(id: "call", name: "inspect", arguments: .object([:]))
                let message = AgentTranscriptMessage(role: .assistant, toolCalls: [call], createdAt: date)
                let snapshot = AgentRunSnapshot(
                    conversationID: conversationID, state: .completed, permissionMode: .askForApproval,
                    messages: [message], startedAt: date.addingTimeInterval(Double(runIndex)))
                context.insert(PersistentAgentRun(snapshot))
                context.insert(PersistentAgentMessage(message, runID: snapshot.id, sequence: 0))
                let invocation = AgentToolInvocation(runID: snapshot.id, call: call, sourceMessageID: message.id)
                context.insert(PersistentAgentToolInvocation(invocation, state: "finished"))
                let output = "\(conversationIndex)/\(runIndex)"
                context.insert(
                    PersistentAgentToolResult(.init(callID: call.id, content: output), invocation: invocation))
                let resultID = AgentTranscriptMessage.toolResultID(runID: snapshot.id, callID: call.id)
                expectedMessages[conversationID, default: []].append(contentsOf: [message.id, resultID])
                expectedOutput[snapshot.id] = output
            }
        }
        try context.save()
        let repository = SwiftDataAgentRunRepository(context: context)
        var mainActorProgressed = false
        let mainActorWork = Task { @MainActor in mainActorProgressed = true }
        let restored = try await repository.loadConversations()
        #expect(mainActorProgressed)
        await mainActorWork.value

        #expect(restored.count == expectedMessages.count)
        for conversation in restored {
            #expect(conversation.messages.map(\.id) == expectedMessages[conversation.id])
            for message in conversation.messages where message.role == .tool {
                let runID = try #require(conversation.messageRunIDs[message.id])
                #expect(message.text == expectedOutput[runID])
            }
            for card in conversation.toolCards {
                #expect(card.result?.content == expectedOutput[card.invocation.runID])
            }
        }
    }

    @Test func historyReadsRetainPendingEditsWithoutSavingUnrelatedChanges() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let context = container.mainContext
        let repository = SwiftDataAgentRunRepository(context: context)
        let conversation = PersistentAgentConversation(id: UUID(), title: "Pending title")
        context.insert(conversation)

        let restored = try await repository.loadConversations()
        #expect(restored.first?.title == "Pending title")
        #expect(context.hasChanges)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PersistentAgentConversation>()) == 0)
    }

    @Test func laterReadsObserveSavedEditsAndDeletedConversations() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .completed, permissionMode: .askForApproval,
            messages: [AgentTranscriptMessage(role: .user, text: "Original")])
        try await repository.save(snapshot)
        #expect(try await repository.loadConversations().first?.messages.first?.text == "Original")
        try await repository.setTitle("Changed title", conversationID: snapshot.conversationID)
        #expect(try await repository.loadConversations().first?.title == "Changed title")
        try await repository.deleteConversation(snapshot.conversationID)
        #expect(try await repository.loadConversations().isEmpty)
    }
}

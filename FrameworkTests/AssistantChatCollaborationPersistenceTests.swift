import AgentKit
import Foundation
import SwiftData
import Testing

@testable import TermindApplication
@testable import TermindPersistence

@Suite
@MainActor
struct AssistantChatCollaborationPersistenceTests {
    @Test
    func inMemoryDeliveredReceiptRejectsStaleSave() throws {
        let store = InMemoryAssistantChatCollaborationStore()
        let receipt = AssistantChatDeliveryReceipt(
            sourceConversationID: UUID(), targetConversationID: UUID(),
            sourceRunID: UUID(), sourceToolCallID: "send", messageID: UUID(),
            state: .queued)
        try store.save(receipt)
        try store.updateReceipt(messageID: receipt.messageID, state: .delivered, failure: nil)

        try store.save(receipt)

        let saved = try #require(
            try store.receipt(
                sourceRunID: receipt.sourceRunID, sourceToolCallID: receipt.sourceToolCallID))
        #expect(saved.state == .delivered)
        #expect(saved.failure == nil)
    }

    @Test
    func messagePersistenceConfirmsReceiptAcrossContextsWithoutLaterDowngrade() async throws {
        let container = try TermindPersistence.makeContainer(inMemory: true)
        let receiptStore = SwiftDataAssistantChatCollaborationStore(
            context: ModelContext(container))
        let repository = SwiftDataAgentRunRepository(context: ModelContext(container))
        let sourceConversationID = UUID()
        let targetConversationID = UUID()
        let sourceRunID = UUID()
        let message = AgentTranscriptMessage(
            role: .user, text: "Routed message",
            origin: AgentMessageOrigin(
                sourceConversationID: sourceConversationID, sourceRunID: sourceRunID,
                sourceToolCallID: "send"))
        let queued = AssistantChatDeliveryReceipt(
            sourceConversationID: sourceConversationID,
            targetConversationID: targetConversationID,
            sourceRunID: sourceRunID,
            sourceToolCallID: "send",
            messageID: message.id,
            state: .queued)
        try receiptStore.save(queued)

        let now = Date.now
        try await repository.save(
            AgentRunSnapshot(
                conversationID: targetConversationID, state: .completed,
                permissionMode: .askForApproval, messages: [message], startedAt: now,
                finishedAt: now))

        #expect(
            try receiptStore.receipt(
                sourceRunID: sourceRunID, sourceToolCallID: "send"
            )?.state == .delivered)

        // A caller may still hold the queued reservation it inserted before the
        // repository transaction. Saving that stale value must remain monotonic.
        try receiptStore.save(queued)
        try receiptStore.updateReceipt(
            messageID: message.id, state: .undelivered, failure: "stale callback")
        let final = try #require(
            try receiptStore.receipt(sourceRunID: sourceRunID, sourceToolCallID: "send"))
        #expect(final.state == .delivered)
        #expect(final.failure == nil)
    }
}

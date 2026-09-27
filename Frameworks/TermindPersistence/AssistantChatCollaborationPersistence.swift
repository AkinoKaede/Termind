import AgentKit
import Foundation
import SwiftData
import TermindApplication

/// Additive sidecar; the historical message model remains frozen.
@Model
public final class PersistentAgentMessageOrigin {
    @Attribute(.unique) public var messageID: UUID = UUID()
    public var sourceConversationID: UUID = UUID()
    public var sourceRunID: UUID = UUID()
    public var sourceToolCallID = ""
    public var sourceTitle: String?

    public init(messageID: UUID, origin: AgentMessageOrigin) {
        self.messageID = messageID
        sourceConversationID = origin.sourceConversationID
        sourceRunID = origin.sourceRunID
        sourceToolCallID = origin.sourceToolCallID
        sourceTitle = origin.sourceTitle.map(AgentPersistenceRedactor.visibleText)
    }

    public var value: AgentMessageOrigin {
        AgentMessageOrigin(
            sourceConversationID: sourceConversationID, sourceRunID: sourceRunID,
            sourceToolCallID: sourceToolCallID, sourceTitle: sourceTitle)
    }
}

@Model
public final class PersistentAgentConversationOrigin {
    @Attribute(.unique) public var conversationID: UUID = UUID()
    public var sourceConversationID: UUID = UUID()
    public var sourceRunID: UUID = UUID()
    public var sourceToolCallID = ""

    public init(_ value: AssistantChatCreationRelation) {
        conversationID = value.conversationID
        sourceConversationID = value.sourceConversationID
        sourceRunID = value.sourceRunID
        sourceToolCallID = value.sourceToolCallID
    }
}

@Model
public final class PersistentAgentDeliveryReceipt {
    @Attribute(.unique) public var id: UUID = UUID()
    /// Unique source-run/tool-call key prevents retries from duplicating delivery.
    @Attribute(.unique) public var dedupeKey = ""
    public var sourceConversationID: UUID = UUID()
    public var targetConversationID: UUID = UUID()
    public var sourceRunID: UUID = UUID()
    public var sourceToolCallID = ""
    public var messageID: UUID = UUID()
    public var state = AgentMessageDeliveryState.queued.rawValue
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()
    public var failure: String?

    public init(_ value: AssistantChatDeliveryReceipt) {
        id = value.id
        dedupeKey = Self.key(runID: value.sourceRunID, toolCallID: value.sourceToolCallID)
        update(value)
    }

    public func update(_ value: AssistantChatDeliveryReceipt) {
        let preservesDelivered =
            state == AgentMessageDeliveryState.delivered.rawValue
            && value.state != .delivered
        sourceConversationID = value.sourceConversationID
        targetConversationID = value.targetConversationID
        sourceRunID = value.sourceRunID
        sourceToolCallID = value.sourceToolCallID
        messageID = value.messageID
        if !preservesDelivered { state = value.state.rawValue }
        createdAt = value.createdAt
        if !preservesDelivered {
            updatedAt = value.updatedAt
            failure = value.failure.map(AgentPersistenceRedactor.visibleText)
        }
    }

    public var value: AssistantChatDeliveryReceipt? {
        guard let state = AgentMessageDeliveryState(rawValue: state) else { return nil }
        return AssistantChatDeliveryReceipt(
            id: id, sourceConversationID: sourceConversationID,
            targetConversationID: targetConversationID, sourceRunID: sourceRunID,
            sourceToolCallID: sourceToolCallID, messageID: messageID, state: state,
            createdAt: createdAt, updatedAt: updatedAt, failure: failure)
    }

    public static func key(runID: UUID, toolCallID: String) -> String {
        "\(runID.uuidString.lowercased())\u{0}\(toolCallID)"
    }
}

@MainActor
public final class SwiftDataAssistantChatCollaborationStore: AssistantChatCollaborationStoring {
    private let container: ModelContainer

    public init(context: ModelContext) { container = context.container }

    public var confirmsDeliveryDuringMessagePersistence: Bool { true }

    public func receipt(sourceRunID: UUID, sourceToolCallID: String) throws
        -> AssistantChatDeliveryReceipt?
    {
        let context = ModelContext(container)
        let key = PersistentAgentDeliveryReceipt.key(
            runID: sourceRunID, toolCallID: sourceToolCallID)
        return try context.fetch(
            FetchDescriptor<PersistentAgentDeliveryReceipt>(
                predicate: #Predicate { $0.dedupeKey == key })
        ).first?.value
    }

    public func save(_ receipt: AssistantChatDeliveryReceipt) throws {
        let context = ModelContext(container)
        let key = PersistentAgentDeliveryReceipt.key(
            runID: receipt.sourceRunID, toolCallID: receipt.sourceToolCallID)
        if let row = try context.fetch(
            FetchDescriptor<PersistentAgentDeliveryReceipt>(
                predicate: #Predicate { $0.dedupeKey == key })
        ).first {
            row.update(receipt)
        } else {
            context.insert(PersistentAgentDeliveryReceipt(receipt))
        }
        try context.savePendingChanges()
    }

    public func updateReceipt(
        messageID: UUID, state: AgentMessageDeliveryState, failure: String?
    ) throws {
        let context = ModelContext(container)
        let rows = try context.fetch(
            FetchDescriptor<PersistentAgentDeliveryReceipt>(
                predicate: #Predicate { $0.messageID == messageID }))
        for row in rows where row.state != AgentMessageDeliveryState.delivered.rawValue || state == .delivered {
            row.state = state.rawValue
            row.failure = failure.map(AgentPersistenceRedactor.visibleText)
            row.updatedAt = .now
        }
        if !rows.isEmpty { try context.savePendingChanges() }
    }

    public func receipts(targetConversationID: UUID) throws -> [AssistantChatDeliveryReceipt] {
        let context = ModelContext(container)
        return try context.fetch(
            FetchDescriptor<PersistentAgentDeliveryReceipt>(
                predicate: #Predicate { $0.targetConversationID == targetConversationID },
                sortBy: [SortDescriptor(\.createdAt)])
        )
        .compactMap(\.value)
    }

    public func save(_ relation: AssistantChatCreationRelation) throws {
        let context = ModelContext(container)
        let id = relation.conversationID
        guard
            try context.fetch(
                FetchDescriptor<PersistentAgentConversationOrigin>(
                    predicate: #Predicate { $0.conversationID == id })
            ).isEmpty
        else { return }
        context.insert(PersistentAgentConversationOrigin(relation))
        try context.savePendingChanges()
    }

    public func deleteRelation(conversationID: UUID) throws {
        let context = ModelContext(container)
        let rows = try context.fetch(
            FetchDescriptor<PersistentAgentConversationOrigin>(
                predicate: #Predicate { $0.conversationID == conversationID }))
        for row in rows { context.delete(row) }
        if !rows.isEmpty { try context.savePendingChanges() }
    }
}

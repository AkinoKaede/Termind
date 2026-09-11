import AgentKit
import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentAgentConversation {
    @Attribute(.unique) public var id: UUID = UUID()
    public var title = ""
    public var customTitle = ""
    public var isPinned = false
    public var archivedAt: Date?
    public var createdAt: Date = Date()
    public var updatedAt: Date = Date()

    public init(id: UUID, title: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
public final class PersistentAgentConversationOrder {
    @Attribute(.unique) public var conversationID: UUID = UUID()
    public var sortIndex = 0.0

    public init(conversationID: UUID, sortIndex: Double) {
        self.conversationID = conversationID
        self.sortIndex = sortIndex
    }
}

@Model
public final class PersistentAgentRun {
    @Attribute(.unique) public var id: UUID = UUID()
    public var conversationID: UUID = UUID()
    public var state = AgentRunState.idle.rawValue
    public var permissionMode = AgentPermissionMode.askForApproval.rawValue
    public var startedAt: Date = Date()
    public var finishedAt: Date?
    public var failure: String?

    public init(_ snapshot: AgentRunSnapshot) {
        id = snapshot.id
        update(snapshot)
    }

    public func update(_ snapshot: AgentRunSnapshot) {
        conversationID = snapshot.conversationID
        state = snapshot.state.rawValue
        permissionMode = snapshot.permissionMode.rawValue
        startedAt = snapshot.startedAt
        finishedAt = snapshot.finishedAt
        failure = snapshot.failure.map(AgentPersistenceRedactor.visibleText)
    }
}

@Model
public final class PersistentAgentMessage {
    @Attribute(.unique) public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var role = AgentTranscriptRole.user.rawValue
    public var text = ""
    public var authoredText: String?
    /// Encoded native image parts attached to the message.
    public var imagesData = Data()
    /// Provider-authored, display-safe reasoning summaries. Opaque signatures
    /// and encrypted provider state deliberately remain in memory only.
    public var reasoningData = Data()
    public var toolCallsData = Data()
    public var toolCallID: String?
    public var toolName: String?
    public var isError = false
    /// Marks a synthetic compaction summary in replay history.
    public var isCompaction = false
    /// Position inside the run's replay transcript. Timestamps are presentation
    /// data and can collide at database precision, so they cannot be the sole
    /// ordering key for model history.
    public var sequence = 0
    public var createdAt: Date = Date()

    public init(_ message: AgentTranscriptMessage, runID: UUID, sequence: Int) {
        id = message.id
        self.runID = runID
        role = message.role.rawValue
        text = AgentPersistenceRedactor.visibleText(
            AgentSecretLifecycle.persistedResultText(
                toolName: message.toolName, original: message.text
            )
        )
        authoredText = message.authoredText.map(AgentPersistenceRedactor.visibleText)
        imagesData = (try? JSONEncoder().encode(message.images)) ?? Data()
        reasoningData = AgentPersistenceRedactor.encoded(
            message.reasoning.map { block in
                AgentReasoningBlock(
                    id: block.id,
                    text: AgentPersistenceRedactor.visibleText(block.text),
                    createdAt: block.createdAt
                )
            })
        toolCallsData = AgentPersistenceRedactor.encoded(
            message.toolCalls.map { call in
                AgentToolCall(
                    id: call.id, name: call.name,
                    arguments: AgentPersistenceRedactor.redactedJSON(call.arguments),
                    providerItemID: call.providerItemID
                )
            })
        toolCallID = message.toolCallID
        toolName = message.toolName
        isError = message.isError
        isCompaction = message.isCompaction
        self.sequence = sequence
        createdAt = message.createdAt
    }
}

/// A compaction is conversation state, not output produced by an agent run.
/// Keeping it in its own table preserves the complete run/message graph for the
/// transcript reader while giving restore an exact model-context boundary.
@Model
public final class PersistentAgentCompaction {
    @Attribute(.unique) public var id: UUID = UUID()
    public var conversationID: UUID = UUID()
    public var summaryMessageID: UUID = UUID()
    public var compactedThroughMessageID: UUID?
    public var sequence = 0
    public var summary = ""
    public var summarizedTokens = 0
    public var keptTokens = 0
    public var displayAnchor: Date = Date()
    public var compactedAt: Date = Date()

    public init(_ record: AgentCompactionRecord, conversationID: UUID) {
        id = record.id
        self.conversationID = conversationID
        summaryMessageID = record.summaryMessageID
        compactedThroughMessageID = record.compactedThroughMessageID
        sequence = record.sequence
        summary = AgentPersistenceRedactor.visibleText(record.summary)
        summarizedTokens = record.summarizedTokens
        keptTokens = record.keptTokens
        displayAnchor = record.displayAnchor
        compactedAt = record.compactedAt
    }

    public var value: AgentCompactionRecord {
        AgentCompactionRecord(
            id: id, summaryMessageID: summaryMessageID,
            compactedThroughMessageID: compactedThroughMessageID,
            sequence: sequence, summary: summary,
            summarizedTokens: summarizedTokens, keptTokens: keptTokens,
            displayAnchor: displayAnchor, compactedAt: compactedAt
        )
    }
}

/// V3 storage for original context snapshots. A separate model keeps the V2
/// message schema frozen and makes the migration an additive lightweight one.
@Model
public final class PersistentAgentContextAttachments {
    @Attribute(.unique) public var messageID: UUID = UUID()
    @Attribute(.externalStorage) public var attachmentsData = Data()

    public init(messageID: UUID, attachments: [AgentContextAttachment]) {
        self.messageID = messageID
        attachmentsData = (try? JSONEncoder().encode(attachments)) ?? Data()
    }

    public var attachments: [AgentContextAttachment] {
        (try? JSONDecoder().decode(
            [AgentContextAttachment].self, from: attachmentsData
        )) ?? []
    }
}

@Model
public final class PersistentAgentToolInvocation {
    @Attribute(.unique) public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var callID = ""
    public var toolName = ""
    public var argumentsData = Data()
    /// Assistant message that requested the tool invocation, when applicable.
    public var sourceMessageID: UUID?
    public var targetHostID: UUID?
    public var state = "proposed"
    public var createdAt: Date = Date()

    public init(_ invocation: AgentToolInvocation, state: String) {
        id = invocation.id
        runID = invocation.runID
        callID = invocation.call.id
        toolName = invocation.call.name
        argumentsData = AgentPersistenceRedactor.redactedJSON(invocation.call.arguments).encodedData
        sourceMessageID = invocation.sourceMessageID
        targetHostID = invocation.targetHostID
        self.state = state
        createdAt = invocation.createdAt
    }
}

@Model
public final class PersistentAgentToolResult {
    @Attribute(.unique) public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var invocationID: UUID = UUID()
    public var callID = ""
    public var content = ""
    public var isError = false
    public var isTruncated = false
    public var metadataData = Data()

    public init(_ result: AgentToolResult, invocation: AgentToolInvocation) {
        runID = invocation.runID
        invocationID = invocation.id
        callID = result.callID
        content = AgentPersistenceRedactor.visibleText(
            AgentSecretLifecycle.persistedResultText(
                toolName: invocation.call.name, original: result.content
            )
        )
        isError = result.isError
        isTruncated = result.isTruncated || content.count < result.content.count
        metadataData = AgentPersistenceRedactor.encoded(result.metadata)
    }
}

@Model
public final class PersistentAgentReviewRecord {
    @Attribute(.unique) public var id: UUID = UUID()
    public var runID: UUID = UUID()
    public var invocationID: UUID = UUID()
    public var status = "started"
    public var verdict: String?
    public var risk: String?
    public var userAuthorization: String?
    public var reason: String?
    public var createdAt: Date = Date()

    public init(runID: UUID, invocationID: UUID, decision: SecurityReviewDecision?) {
        self.runID = runID
        self.invocationID = invocationID
        if let decision {
            status = "finished"
            verdict = decision.verdict.rawValue
            risk = decision.risk.rawValue
            userAuthorization = decision.userAuthorization.rawValue
            reason = AgentPersistenceRedactor.visibleText(decision.reason)
        }
    }

    public init(runID: UUID, invocationID: UUID, failure: String, timedOut: Bool) {
        self.runID = runID
        self.invocationID = invocationID
        status = timedOut ? "timedOut" : "failed"
        reason = AgentPersistenceRedactor.visibleText(failure)
    }
}

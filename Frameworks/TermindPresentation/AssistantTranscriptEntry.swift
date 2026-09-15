import AgentKit
import Foundation
import TermindApplication

/// Stable rows shared by the macOS and iOS ListViewKit transcript adapters.
nonisolated public struct AssistantTranscriptEntry: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case empty
        case user
        case assistant
        case tool
        case work
        case command
        case plan
        case compaction
        case compactionActivity
        case failure
        case interrupted
    }

    public enum Content: Hashable, Sendable {
        case empty
        case user(ChatMessage, canEdit: Bool)
        case assistant(ChatMessage, canFork: Bool)
        case tool(AgentToolCard)
        case work(AgentWorkGroup)
        case command(SuggestedCommand)
        case plan(AgentPlanCard)
        case compaction(AgentCompactionMark)
        case compactionActivity(AgentCompactionActivity)
        case failure(AgentRunFailureNotice)
        case interrupted
    }

    public let id: UUID
    public let content: Content
    public let hasLeadingSpacing: Bool

    public init(id: UUID, content: Content, hasLeadingSpacing: Bool = false) {
        self.id = id
        self.content = content
        self.hasLeadingSpacing = hasLeadingSpacing
    }

    private static let emptyID = UUID(uuidString: "00E48921-70E7-493A-9EB3-44727BC2145B")!
    private static let interruptedID = UUID(uuidString: "FD8D34B6-E81F-4DC8-91E8-479AD9ACF5CB")!

    public static func items(
        timeline: [TimelineItem],
        isInterrupted: Bool,
        canEdit: (UUID) -> Bool,
        canFork: (UUID) -> Bool
    ) -> [Self] {
        if timeline.isEmpty { return [.init(id: emptyID, content: .empty)] }
        var result = timeline.enumerated().map { index, item in
            let content: Content =
                switch item {
                case .message(let message) where message.role == .user:
                    .user(message, canEdit: canEdit(message.id))
                case .message(let message):
                    .assistant(message, canFork: canFork(message.id))
                case .tool(let card): .tool(card)
                case .work(let group): .work(group)
                case .command(let command): .command(command)
                case .plan(let card): .plan(card)
                case .compaction(let mark): .compaction(mark)
                case .compactionActivity(let activity): .compactionActivity(activity)
                case .failure(let failure): .failure(failure)
                }
            return Self(id: item.id, content: content, hasLeadingSpacing: index > 0)
        }
        if isInterrupted {
            result.append(.init(id: interruptedID, content: .interrupted, hasLeadingSpacing: true))
        }
        return result
    }

    public var presentationIDs: Set<UUID> {
        var result: Set<UUID> = [id]
        guard case .work(let group) = content else { return result }
        for item in group.items {
            result.insert(item.id)
            if case .tools(let batch) = item { result.formUnion(batch.cards.map(\.id)) }
        }
        return result
    }

    public var kind: Kind {
        switch content {
        case .empty: .empty
        case .user: .user
        case .assistant: .assistant
        case .tool: .tool
        case .work: .work
        case .command: .command
        case .plan: .plan
        case .compaction: .compaction
        case .compactionActivity: .compactionActivity
        case .failure: .failure
        case .interrupted: .interrupted
        }
    }
}

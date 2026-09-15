import AgentKit
import Foundation
import TermindDomain

/// A command the model proposed. It is *never* executed on the model's say-so —
/// `risk` is computed locally by `CommandRiskClassifier` and the user always
/// clicks.
nonisolated public struct SuggestedCommand: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var command: String
    public var explanation: String = ""
    public var createdAt: Date = .now

    public var risk: RiskAssessment {
        CommandRiskClassifier.assess(command)
    }

    public init(id: UUID = UUID(), command: String, explanation: String = "", createdAt: Date = .now) {
        self.id = id
        self.command = command
        self.explanation = explanation
        self.createdAt = createdAt
    }
}

/// One user-facing piece of context attached to an LLM conversation.
///
/// Output, selections, and file contents must be added explicitly. The pinned
/// host and directory pills are also chips, but they are built from the
/// surface's `SessionContext` rather than held here — see that type. Shell
/// Integration's narrow OS/kernel metadata is never a chip at all; it is
/// transient, token-sanitized, and disclosed by the setting that enables it.
///
/// `content` is the payload, not decoration. A chip carrying only a label while
/// its data travels by some other route — as the SSH-failure attachment did, by
/// pasting the log into the draft — discloses nothing.
nonisolated public struct ContextChip: Identifiable, Hashable, Sendable {
    /// `CaseIterable` so `blockName` can be read backwards: a composed message
    /// carries these tags into the transcript, and rendering one as an
    /// attachment row means recognising the tag it came from.
    public nonisolated enum Kind: Hashable, Sendable, CaseIterable {
        case host, directory, output, selection, file, image, pastedText

        public var symbol: String {
            switch self {
            case .host: "server.rack"
            case .directory: "folder"
            case .output: "text.alignleft"
            case .selection: "text.cursor"
            case .file: "doc"
            case .image: "photo"
            case .pastedText: "doc.on.clipboard"
            }
        }

        /// Names the block this chip becomes inside the sent message.
        public var blockName: String {
            switch self {
            case .host: "host"
            case .directory: "directory"
            case .output: "output"
            case .selection: "selection"
            case .file: "file"
            case .image: "image"
            case .pastedText: "pasted_text"
            }
        }
    }

    public var id: UUID = UUID()
    public var kind: Kind
    public var label: String
    public var content: String = ""
    public var image: AgentImageAttachment? = nil
    /// Original non-image bytes used only to reopen a sent attachment. The
    /// model still receives `content`, which is the validated extraction.
    public var sourceAttachment: AgentContextAttachment? = nil

    public var contextAttachment: AgentContextAttachment? {
        guard image == nil, let attachmentKind = kind.agentAttachmentKind else { return nil }
        if let sourceAttachment {
            return AgentContextAttachment(
                id: id, kind: attachmentKind, label: label,
                contentTypeIdentifier: sourceAttachment.contentTypeIdentifier,
                suggestedFilename: sourceAttachment.suggestedFilename,
                data: sourceAttachment.data,
                isOriginalFile: sourceAttachment.isOriginalFile
            )
        }
        return AgentContextAttachment(
            id: id, kind: attachmentKind, label: label,
            contentTypeIdentifier: "public.plain-text",
            suggestedFilename: kind.fallbackFilename(for: label),
            data: Data(content.utf8), isOriginalFile: false
        )
    }

    /// Derived, not declared. A hand-passed count is a number that was true
    /// once, and the estimate exists to warn about payload size.
    ///
    /// Shares `AgentContextEstimator`'s divisor rather than repeating `/ 4`, so
    /// a chip and the context gauge can never quote different sizes for the
    /// same attachment.
    public var approximateTokens: Int {
        if let image {
            let tilesWide = max(1, Int(ceil(Double(image.pixelWidth) / 512)))
            let tilesHigh = max(1, Int(ceil(Double(image.pixelHeight) / 512)))
            return 85 + 170 * tilesWide * tilesHigh
        }
        return max(1, AgentContextEstimator.tokens(inCharacters: content.count))
    }

    /// Recovers the text the user actually typed from a persisted model-facing
    /// turn. Attachment payloads remain in that turn for replay, but projecting
    /// a 200,000-character PDF extraction into Markdown makes opening history
    /// unnecessarily expensive and is not useful conversation UI.
    public static func visiblePrompt(in composedText: String) -> String {
        guard let boundary = payloadBoundary(in: composedText) else { return composedText }
        return String(composedText[..<boundary])
    }

    /// Rebuilds lightweight bubble chips from the model-facing markup without
    /// retaining or rendering the payload between the tags.
    public static func visibleReferences(
        in composedText: String, images: [AgentImageAttachment] = [],
        contextAttachments: [AgentContextAttachment] = []
    ) -> [ContextChipReference] {
        let boundary = payloadBoundary(in: composedText)

        var matches: [(String.Index, ContextChipReference)] = []
        var unusedAttachments = contextAttachments
        if let boundary {
            let suffix = composedText[boundary...]
            for kind in Kind.allCases where kind != .image {
                let prefix = "<\(kind.blockName) label=\""
                var cursor = suffix.startIndex
                while let opening = suffix.range(of: prefix, range: cursor..<suffix.endIndex) {
                    let labelStart = opening.upperBound
                    guard
                        let labelEnd = suffix.range(
                            of: "\">", range: labelStart..<suffix.endIndex
                        )
                    else { break }
                    let contentStart = labelEnd.upperBound
                    let closing = "</\(kind.blockName)>"
                    guard
                        let contentEnd = suffix.range(
                            of: closing, range: contentStart..<suffix.endIndex
                        )
                    else { break }
                    let label = String(suffix[labelStart..<labelEnd.lowerBound])
                    let storedIndex = unusedAttachments.firstIndex {
                        $0.label.replacingOccurrences(of: "\"", with: "'") == label
                            && $0.kind == kind.agentAttachmentKind
                    }
                    let attachment: AgentContextAttachment? =
                        storedIndex.map {
                            unusedAttachments.remove(at: $0)
                        }
                        ?? kind.fallbackAttachment(
                            label: label,
                            content: String(suffix[contentStart..<contentEnd.lowerBound])
                        )
                    matches.append(
                        (
                            opening.lowerBound,
                            ContextChipReference(
                                id: attachment?.id ?? UUID(), kind: kind,
                                label: attachment?.label ?? label,
                                attachment: attachment
                            )
                        ))
                    cursor = contentEnd.upperBound
                }
            }
        }

        let textReferences = matches.sorted { $0.0 < $1.0 }.map(\.1)
        let imageReferences = images.map {
            ContextChipReference(id: $0.id, kind: .image, label: $0.label)
        }
        return textReferences + imageReferences
    }

    private static func payloadBoundary(in text: String) -> String.Index? {
        Kind.allCases.compactMap {
            text.range(of: "\n\n<\($0.blockName) label=\"")?.lowerBound
        }.min()
    }

    public init(
        id: UUID = UUID(), kind: Kind, label: String, content: String = "", image: AgentImageAttachment? = nil,
        sourceAttachment: AgentContextAttachment? = nil
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.content = content
        self.image = image
        self.sourceAttachment = sourceAttachment
    }
}

/// The non-payload part of a Context Chip kept by the display projection.
///
/// A sent PDF can contain 200,000 characters; the bubble needs only these few
/// bytes to show what accompanied the prompt.
nonisolated public struct ContextChipReference: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var kind: ContextChip.Kind
    public var label: String
    public var attachment: AgentContextAttachment? = nil

    public init(id: UUID = UUID(), kind: ContextChip.Kind, label: String, attachment: AgentContextAttachment? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.attachment = attachment
    }
}

extension ContextChip.Kind {
    fileprivate nonisolated var agentAttachmentKind: AgentContextAttachment.Kind? {
        switch self {
        case .file: .file
        case .output: .output
        case .selection: .selection
        case .pastedText: .pastedText
        case .host: .host
        case .directory: .directory
        case .image: nil
        }
    }

    fileprivate nonisolated func fallbackAttachment(
        label: String, content: String
    ) -> AgentContextAttachment? {
        guard let kind = agentAttachmentKind else { return nil }
        var text = content
        if text.hasPrefix("\n") { text.removeFirst() }
        if text.hasSuffix("\n") { text.removeLast() }
        return AgentContextAttachment(
            kind: kind, label: label, contentTypeIdentifier: "public.plain-text",
            suggestedFilename: fallbackFilename(for: label), data: Data(text.utf8),
            isOriginalFile: false
        )
    }

    fileprivate nonisolated func fallbackFilename(for label: String) -> String {
        if self == .file {
            let stem = (label as NSString).deletingPathExtension
            return "\(stem.isEmpty ? label : stem) extracted.txt"
        }
        return (label as NSString).pathExtension.isEmpty ? "\(label).txt" : label
    }
}

nonisolated public struct PendingContextAttachment: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var label: String

    public init(id: UUID = UUID(), label: String) {
        self.id = id
        self.label = label
    }
}

nonisolated public struct ChatMessage: Identifiable, Hashable, Sendable {
    public nonisolated enum Role: Hashable, Sendable {
        case user, assistant
    }

    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var reasoning: [AgentReasoningBlock] = []
    public var contextChips: [ContextChipReference] = []
    public var images: [AgentImageAttachment] = []
    public var commands: [SuggestedCommand] = []
    /// True while tokens are still arriving, so the view can show a caret.
    public var isStreaming: Bool = false
    /// Orders this message against the tool cards, which are a separate list.
    /// Restored conversations carry their stored time so history does not
    /// re-sort itself behind every card the moment a window opens.
    public var createdAt: Date = .now

    public init(
        id: UUID = UUID(), role: Role, text: String, reasoning: [AgentReasoningBlock] = [],
        contextChips: [ContextChipReference] = [], images: [AgentImageAttachment] = [],
        commands: [SuggestedCommand] = [], isStreaming: Bool = false, createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.reasoning = reasoning
        self.contextChips = contextChips
        self.images = images
        self.commands = commands
        self.isStreaming = isStreaming
        self.createdAt = createdAt
    }
}

nonisolated public struct AgentToolCard: Identifiable, Hashable, Sendable {
    public nonisolated enum State: String, Hashable, Sendable {
        case proposed, waitingForApproval, waitingForUser, reviewing, running, completed, denied, failed
        case interrupted

        public var isTerminal: Bool {
            switch self {
            case .completed, .denied, .failed, .interrupted: true
            case .proposed, .waitingForApproval, .waitingForUser, .reviewing, .running: false
            }
        }
    }

    public var id: UUID { invocation.id }
    public var invocation: AgentToolInvocation
    public var descriptor: AgentToolDescriptor
    public var state: State = .proposed
    public var result: AgentToolResult?
    public var review: GuardianDecision?

    /// `terminal_suggest` is a user-facing artifact, like `present_plan`, not
    /// work detail. Once the tool has completed, promote its validated input to
    /// the transcript and remove the protocol row from Worked.
    public var terminalSuggestion: SuggestedCommand? {
        guard descriptor.name == "terminal_suggest",
            state == .completed,
            result?.isError == false,
            let arguments = invocation.call.arguments.objectValue,
            let command = arguments["command"]?.stringValue,
            !command.isEmpty
        else { return nil }
        return SuggestedCommand(
            id: id,
            command: command,
            explanation: arguments["explanation"]?.stringValue ?? "",
            createdAt: invocation.createdAt
        )
    }

    public init(
        invocation: AgentToolInvocation, descriptor: AgentToolDescriptor, state: State = .proposed,
        result: AgentToolResult? = nil, review: GuardianDecision? = nil
    ) {
        self.invocation = invocation
        self.descriptor = descriptor
        self.state = state
        self.result = result
        self.review = review
    }
}

/// One message the user sent while a run was in flight, waiting on the next
/// model boundary.
///
/// `draft` and `attachments` are kept beside the composed message because the
/// queue is a promise that can be broken — a stopped run hands these back to the
/// composer, and handing back `message.text` would return the user their own
/// attachment blocks to edit.
nonisolated public struct PendingSteeringMessage: Identifiable, Hashable, Sendable {
    /// The message's own id, so delivery is matched on identity rather than on
    /// comparing text with text.
    public var id: AgentTranscriptMessage.ID { message.id }
    public var draft: String
    public var attachments: [ContextChip] = []
    public var message: AgentTranscriptMessage

    public init(draft: String, attachments: [ContextChip] = [], message: AgentTranscriptMessage) {
        self.draft = draft
        self.attachments = attachments
        self.message = message
    }
}

/// One row of a conversation, whichever of the two lists it came from.
nonisolated public enum TimelineItem: Identifiable, Hashable, Sendable {
    case message(ChatMessage)
    case tool(AgentToolCard)
    case work(AgentWorkGroup)
    case command(SuggestedCommand)
    case plan(AgentPlanCard)
    case compaction(AgentCompactionMark)
    case compactionActivity(AgentCompactionActivity)

    public var id: UUID {
        switch self {
        case .message(let message): message.id
        case .tool(let card): card.id
        case .work(let group): group.id
        case .command(let command): command.id
        case .plan(let card): card.id
        case .compaction(let mark): mark.id
        case .compactionActivity(let activity): activity.id
        }
    }

    /// The run's clock, not the UI's — the same stamp `timeline` merges the two
    /// existing lists on. See `AgentEvent.messageStarted`.
    public var orderedAt: Date {
        switch self {
        case .message(let message): message.createdAt
        case .tool(let card): card.invocation.createdAt
        case .work(let group): group.orderedAt
        case .command(let command): command.createdAt
        case .plan(let card): card.createdAt
        case .compaction(let mark): mark.createdAt
        case .compactionActivity(let activity): activity.createdAt
        }
    }

    /// Breaks a tie at the same instant. A compaction mark is anchored to the
    /// last message it summarized, so it belongs *after* that message rather
    /// than in a position `sorted` is free to pick either way — Swift's sort is
    /// not stable, so equal timestamps otherwise swap between redraws.
    public var sortRank: Int {
        switch self {
        case .work: -1
        case .compaction, .compactionActivity: 1
        default: 0
        }
    }

}

nonisolated public struct AgentToolBatch: Identifiable, Hashable, Sendable {
    public var id: UUID { cards.first?.id ?? Self.emptyID }
    public var cards: [AgentToolCard]
    /// Batches are run-scoped rather than provider-turn-scoped. A reasoning
    /// message or another model round trip must not split one visual activity
    /// into a succession of structurally different rows.
    public var runID: UUID
    /// The latest provider-authored reasoning that can temporarily occupy the
    /// batch title. The renderer keeps the Markdown and derives plain text only
    /// for accessibility.
    public var reasoning: AgentToolReasoning?

    private static let emptyID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    public init(cards: [AgentToolCard], runID: UUID, reasoning: AgentToolReasoning? = nil) {
        self.cards = cards
        self.runID = runID
        self.reasoning = reasoning
    }
}

nonisolated public struct AgentToolReasoning: Hashable, Sendable {
    public var sourceMessageID: UUID
    public var markdown: String

    /// Content is part of the revision: every streamed reasoning update earns
    /// its own complete display window, while recycling the same row does not.
    public var revision: String { sourceMessageID.uuidString + "\u{0}" + markdown }

    public init(sourceMessageID: UUID, markdown: String) {
        self.sourceMessageID = sourceMessageID
        self.markdown = markdown
    }
}

nonisolated public enum AgentWorkItem: Identifiable, Hashable, Sendable {
    case reasoning(AgentReasoningBlock)
    case message(ChatMessage)
    case tool(AgentToolCard)
    /// One or more run-scoped tool calls, regardless of their current result.
    /// The view shows activity until every member is terminal, then summarizes.
    case tools(AgentToolBatch)

    public var id: UUID {
        switch self {
        case .reasoning(let block): block.id
        case .message(let message): message.id
        case .tool(let card): card.id
        case .tools(let batch): batch.id
        }
    }

    public var orderedAt: Date {
        switch self {
        case .reasoning(let block): block.createdAt
        case .message(let message): message.createdAt
        case .tool(let card): card.invocation.createdAt
        case .tools(let batch): batch.cards.first?.invocation.createdAt ?? .distantPast
        }
    }
}

nonisolated public struct AgentWorkGroup: Identifiable, Hashable, Sendable {
    public var id: UUID { run.id }
    public var run: AgentRunSummary
    public var items: [AgentWorkItem]
    public var orderedAt: Date
    public var anchorMessageID: UUID?
    public var appearsAfterAnswer: Bool
    /// The provider summary currently receiving deltas. The view scans this
    /// text instead of showing a second generic Working indicator outside.
    public var activeReasoningBlockID: AgentReasoningBlock.ID?

    public init(
        run: AgentRunSummary, items: [AgentWorkItem], orderedAt: Date, anchorMessageID: UUID? = nil,
        appearsAfterAnswer: Bool, activeReasoningBlockID: AgentReasoningBlock.ID? = nil
    ) {
        self.run = run
        self.items = items
        self.orderedAt = orderedAt
        self.anchorMessageID = anchorMessageID
        self.appearsAfterAnswer = appearsAfterAnswer
        self.activeReasoningBlockID = activeReasoningBlockID
    }
}

nonisolated public enum AgentWorkPresentation {
    public static func isExpandedByDefault(
        for state: AgentRunState, appearsAfterAnswer: Bool = false,
        isCompact _: Bool = false
    ) -> Bool {
        // Compact and full Assistant surfaces follow the same disclosure
        // default. Surface-local presentation state still lets a reader fold
        // either one independently.
        state != .completed || appearsAfterAnswer
    }

    /// A compact, stable duration for the work disclosure. Seconds are floored
    /// so a completed run never appears to gain time after its finish event.
    public static func duration(
        from startedAt: Date, to finishedAt: Date, locale: Locale = .current
    ) -> String {
        let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return minutes > 0
                ? AppLocalization.string("\(hours)h \(minutes)m", locale: locale)
                : AppLocalization.string("\(hours)h", locale: locale)
        }
        if minutes > 0 {
            return remainingSeconds > 0
                ? AppLocalization.string("\(minutes)m \(remainingSeconds)s", locale: locale)
                : AppLocalization.string("\(minutes)m", locale: locale)
        }
        return AppLocalization.string("\(remainingSeconds)s", locale: locale)
    }

    public static func title(
        for state: AgentRunState, from startedAt: Date, to finishedAt: Date,
        locale: Locale = .current
    ) -> String {
        let elapsed = duration(from: startedAt, to: finishedAt, locale: locale)
        switch state {
        case .idle, .running, .waitingForUser, .waitingForApproval, .reviewing:
            return AppLocalization.string("Working for \(elapsed)", locale: locale)
        case .cancelled:
            return AppLocalization.string("You stopped after \(elapsed)", locale: locale)
        case .completed, .failed, .interrupted:
            return AppLocalization.string("Worked for \(elapsed)", locale: locale)
        }
    }
}

nonisolated public struct AgentCompactionActivity: Identifiable, Hashable, Sendable {
    public nonisolated enum State: Hashable, Sendable {
        case running
        case failed(String)
    }

    public var id: UUID = UUID()
    public var state: State
    public var createdAt: Date = .now

    public init(id: UUID = UUID(), state: State, createdAt: Date = .now) {
        self.id = id
        self.state = state
        self.createdAt = createdAt
    }
}

/// The line in the transcript where history stopped being sent.
///
/// The messages above it are *not* deleted. Compaction shapes what is sent, and
/// the codebase's rule is that transforms never shape what is kept — see
/// `AgentContextPipeline`. So the conversation stays scrollable and this says
/// where the model's memory of it now begins.
nonisolated public struct AgentCompactionMark: Identifiable, Hashable, Sendable {
    public var id: UUID = UUID()
    public var summarizedTokens: Int
    public var keptTokens: Int
    public var createdAt: Date = .now

    public init(
        id: UUID = UUID(), summarizedTokens: Int, keptTokens: Int,
        createdAt: Date = .now
    ) {
        self.id = id
        self.summarizedTokens = summarizedTokens
        self.keptTokens = keptTokens
        self.createdAt = createdAt
    }

    public init(_ record: AgentCompactionRecord) {
        self.init(
            id: record.id, summarizedTokens: record.summarizedTokens,
            keptTokens: record.keptTokens, createdAt: record.displayAnchor
        )
    }
}

/// A presented plan and what became of it.
///
/// A row of the transcript rather than a panel above the composer: it is part of
/// what happened, in the order it happened, and it stays readable after it has
/// been answered. Nothing is suspended waiting on it — see `AgentPlanModeHook`.
nonisolated public struct AgentPlanCard: Identifiable, Hashable, Sendable {
    public var id: UUID { plan.id }
    public var plan: AgentPlan
    public var outcome: AgentPlan.Outcome = .pending
    /// Ordered against messages and tool cards by the same clock they use.
    public var createdAt: Date { plan.createdAt }

    public init(plan: AgentPlan, outcome: AgentPlan.Outcome = .pending) {
        self.plan = plan
        self.outcome = outcome
    }
}

/// One AI conversation, wherever it is being shown.
///
/// It deliberately knows nothing about a session. Where the conversation is
/// *about* a host and a directory, that comes from the surface showing it —
/// `WindowSidebarState.sessionContext` — because a conversation that owned its
/// own session context carried it into the Assistant destination, which has no session
/// to describe.
@Observable
public final class ConversationModel: Identifiable {
    public let id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var customTitle: String?
    public internal(set) var isHistoryChanging = false
    public var isPinned = false
    public var sortIndex: Double
    public var archivedAt: Date?
    public var messages: [ChatMessage] = []
    public let composer = ConversationComposerState()
    public var attachmentLoader = ContextAttachmentLoading.unavailable
    private var attachmentImportTasks: [PendingContextAttachment.ID: Task<Void, Never>] = [:]
    /// The last state the run reported, before anything outstanding in the UI
    /// is taken into account.
    private var reportedRunState: AgentRunState = .idle

    /// What the transcript shows, ranked from the reported state and actual
    /// outstanding work. There is deliberately no second stored run state.
    public var runState: AgentRunState {
        if reportedRunState.isTerminal || reportedRunState == .idle {
            reportedRunState
        } else if !pendingUserInputs.isEmpty || !pendingSSHAuthentications.isEmpty
            || !pendingSSHHostKeys.isEmpty
        {
            .waitingForUser
        } else if !pendingApprovals.isEmpty {
            .waitingForApproval
        } else if !reviewing.isEmpty {
            .reviewing
        } else {
            reportedRunState
        }
    }

    public var isStreaming: Bool { runState != .idle && !runState.isTerminal }
    public var toolCards: [AgentToolCard] = []
    /// Tool proposals are durable individual events, but publishing each one to
    /// the transcript would briefly draw a single row and then replace it with
    /// a batch. Hold the UI projection until every call from the source message
    /// is known; state/result events update the staged card in place.
    private var stagedToolCards: [UUID: AgentToolCard] = [:]
    private var stagedToolOrder: [UUID] = []
    private var activeTurnMessageID: UUID?
    public private(set) var runSummaries: [UUID: AgentRunSummary] = [:]
    public private(set) var messageRunIDs: [UUID: UUID] = [:]
    private var activeRunID: UUID?
    /// Reasoning is live presentation for one provider round trip, not run
    /// history. The provider copy remains on the transcript for replay, while
    /// this id alone decides whether it is currently visible.
    private var activeReasoningMessageID: UUID?

    /// Questions waiting on the user, oldest first.
    ///
    /// A queue rather than a slot because tools no longer run one at a time. A
    /// turn where two calls both need approval used to overwrite the first
    /// request with the second, and the continuation the first was suspended on
    /// was never resumed — the run simply stopped, with no error and nothing on
    /// screen to answer.
    ///
    /// Only the head is presented. Showing three cards at once would ask
    /// someone to authorize three things while reading one.
    public private(set) var pendingApprovals: [AgentApprovalRequest] = []
    public private(set) var pendingUserInputs: [AgentUserInputRequest] = []
    public private(set) var pendingSSHAuthentications: [AgentSSHAuthenticationRequest] = []
    public private(set) var pendingSSHHostKeys: [AgentSSHHostKeyRequest] = []
    /// What the user typed at a busy agent, oldest first, none of it delivered
    /// yet. See `submitSteeringDraft`.
    public private(set) var pendingSteering: [PendingSteeringMessage] = []
    /// Reviews in flight. Counted rather than flagged: they run concurrently,
    /// so the last one to finish must not be able to announce that none are.
    private var reviewing: Set<UUID> = []

    public var pendingApproval: AgentApprovalRequest? { pendingApprovals.first }
    public var pendingUserInput: AgentUserInputRequest? { pendingUserInputs.first }
    public var pendingSSHAuthentication: AgentSSHAuthenticationRequest? {
        pendingSSHAuthentications.first
    }
    public var pendingSSHHostKey: AgentSSHHostKeyRequest? { pendingSSHHostKeys.first }
    public enum PendingUserInteraction {
        case questions(AgentUserInputRequest)
        case sshAuthentication(AgentSSHAuthenticationRequest)
        case sshHostKey(AgentSSHHostKeyRequest)

        public var createdAt: Date {
            switch self {
            case .questions(let request): request.createdAt
            case .sshAuthentication(let request): request.createdAt
            case .sshHostKey(let request): request.createdAt
            }
        }
    }
    public var pendingUserInteraction: PendingUserInteraction? {
        [
            pendingUserInput.map(PendingUserInteraction.questions),
            pendingSSHAuthentication.map(PendingUserInteraction.sshAuthentication),
            pendingSSHHostKey.map(PendingUserInteraction.sshHostKey),
        ]
        .compactMap { $0 }
        .min { $0.createdAt < $1.createdAt }
    }
    /// What has been filled in so far, keyed by question. One request can now
    /// carry several questions, so the drafts are per question rather than one
    /// pair of fields shared by whichever one happened to be on screen.
    public private(set) var userInputDrafts: [String: AgentUserInputDraft] = [:]
    public private(set) var currentUserInputQuestionIndex = 0
    public private(set) var skippedUserInputQuestionIDs: Set<String> = []
    /// Kept out of `userInputDrafts` on purpose: a secret does not belong in
    /// the same dictionary as text that is echoed back to the model.
    public var secretInputDraft = ""
    /// The model-facing history, which is not what `messages` holds.
    ///
    /// `messages` is a display projection: it has no tool calls and no tool
    /// results, because those are drawn as cards. Replaying it as the next run's
    /// prior context loses every tool the agent already ran, and turns a
    /// tool-only assistant turn into an empty message — which Anthropic and
    /// Google both reject. So the authoritative transcript is kept beside it and
    /// rebuilt from the same events.
    public private(set) var transcript: [AgentTranscriptMessage] = []
    private let contextEstimateTracker: AgentContextEstimateTracker
    public private(set) var contextEstimate: AgentContextEstimate
    private var contextEstimatePublishTask: Task<Void, Never>?
    private var contextEstimateNeedsPublish = false
    private let contextEstimatePublishInterval: Duration
    public private(set) var contextEstimatePublishCount = 0
    private var runtime: AgentRuntime?
    private var eventTask: Task<Void, Never>?
    private var runtimeGeneration: UInt64 = 0
    private var approvalWaiters: [UUID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]
    private var inputWaiters: [UUID: CheckedContinuation<AgentUserInputResponse, Never>] = [:]
    private var userInputTimeoutTask: Task<Void, Never>?
    private(set) var userInputDeadline: ContinuousClock.Instant?
    @ObservationIgnored var questionClockNow: () -> ContinuousClock.Instant = { .now }
    @ObservationIgnored var questionClockSleep: (ContinuousClock.Instant) async throws -> Void = {
        try await Task.sleep(until: $0, clock: .continuous)
    }
    private var sshAuthenticationWaiters: [UUID: CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = [:]
    private var sshHostKeyWaiters: [UUID: CheckedContinuation<AgentSSHHostKeyResponse, Never>] = [:]

    /// Whether the agent may only look.
    ///
    /// Per conversation and deliberately not remembered app-wide the way
    /// `lastSelectedPermissionMode` is. Permission mode is a standing preference
    /// about how much you trust the agent; this is a posture for one task, and a
    /// mode silently inherited by tomorrow's conversation is a mode nobody asked
    /// for.
    public var isPlanning = false

    /// Plans presented in this conversation, oldest first.
    public private(set) var plans: [AgentPlanCard] = []

    /// Where history stopped being sent, oldest first. Display only — durable
    /// `compactionRecords` are authoritative across relaunches; their synthetic
    /// transcript turns exist only in the model-facing projection.
    public private(set) var compactions: [AgentCompactionMark] = []
    public private(set) var compactionRecords: [AgentCompactionRecord] = []

    /// Ephemeral UI state. Successful compactions become boundary marks; a
    /// failed attempt stays readable for this process without entering the
    /// model transcript or persistence schema.
    public private(set) var compactionActivity: AgentCompactionActivity?

    /// True while a compaction is in flight, so the composer can say so and not
    /// start a second one.
    public private(set) var isCompacting = false

    /// The current task list, whole. Replaced rather than patched — see
    /// `AgentTask`.
    public private(set) var tasks: [AgentTask] = []

    public var completedTaskCount: Int { tasks.filter { $0.status == .completed }.count }

    /// How many characters of tool schema the last run sent.
    ///
    /// Recorded when a run starts rather than derived on demand: the registry is
    /// assembled per run from Vault hosts, MCP servers and the search plan, and
    /// a composer redrawing on every keystroke must not rebuild it. Zero until
    /// the first run, which is honest — nothing has been sent yet.
    public private(set) var toolSchemaCharacters = 0

    public func noteToolSchemas(_ descriptors: [AgentToolDescriptor]) {
        toolSchemaCharacters = descriptors.reduce(0) { total, descriptor in
            total + AgentContextEstimator.characterUnits(in: descriptor.name)
                + AgentContextEstimator.characterUnits(in: descriptor.summary)
                + AgentContextEstimator.characterUnits(
                    in: descriptor.inputSchema.encodedString
                )
        }
        contextEstimateTracker.setToolSchemaCharacters(toolSchemaCharacters)
        publishContextEstimateImmediately()
    }

    public var contextEstimateFullRebuildCount: Int {
        contextEstimateTracker.fullRebuildCount
    }

    private var attachedContextCharacters: Int {
        composer.attachments.reduce(0) {
            $0
                + ($1.image == nil
                    ? AgentContextEstimator.characterUnits(in: $1.content)
                    : $1.approximateTokens * AgentContextEstimator.charactersPerToken)
        }
    }

    private func refreshAttachedContextEstimate() {
        contextEstimateTracker.setAttachedCharacters(attachedContextCharacters)
        publishContextEstimateImmediately()
    }

    private func publishContextEstimateImmediately() {
        contextEstimatePublishTask?.cancel()
        contextEstimatePublishTask = nil
        contextEstimateNeedsPublish = false
        let value = contextEstimateTracker.snapshot()
        if contextEstimate != value {
            contextEstimate = value
            contextEstimatePublishCount += 1
        }
    }

    private func scheduleContextEstimatePublish() {
        contextEstimateNeedsPublish = true
        guard contextEstimatePublishTask == nil else { return }
        contextEstimatePublishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: contextEstimatePublishInterval)
            guard !Task.isCancelled else { return }
            contextEstimatePublishTask = nil
            guard contextEstimateNeedsPublish else { return }
            contextEstimateNeedsPublish = false
            let value = contextEstimateTracker.snapshot()
            if contextEstimate != value {
                contextEstimate = value
                contextEstimatePublishCount += 1
            }
        }
    }

    /// What the most recent turn cost, as its provider counted it.
    ///
    /// The newest report wins rather than accumulating: a turn's input already
    /// counts the whole conversation behind it, so this is the size of the
    /// context, not a running total of what has been spent on it.
    ///
    /// `nil` until a turn reports one. A conversation restored from disk starts
    /// here too — usage is not persisted, so a reopened chat shows an estimate
    /// until it next runs. See `AgentContextEstimator`.
    public private(set) var usage: AgentTokenUsage?

    /// Per-conversation reasoning state, normalized against the resolved model
    /// by the composer before a request is made.
    public var reasoningEffort: ReasoningEffort = .medium

    /// An explicit choice for this conversation. `nil` follows the app-wide
    /// last selection through `AIConfigurationModel.resolve(conversation:)`, the same shape
    /// used by `model` below.
    public var permissionMode: AgentPermissionMode?

    /// The model this conversation was told to use, if it was told.
    ///
    /// `nil` is the normal state and is not a missing value — it means "whatever
    /// the Chat role resolves to", which `AIConfigurationModel.resolve(_:)` answers. Keeping
    /// it unset rather than assigning a default on creation is what lets a
    /// change in Settings move every conversation that never chose, and lets one
    /// that did keep its choice.
    ///
    /// A ref rather than a name: two providers can both offer `gpt-5`, and which
    /// key pays for it is the question. The store is not held here — views
    /// resolve through `AppModel`, so a conversation stays a value that knows
    /// nothing about where models come from.
    public var model: AIModelRef?

    /// The generated summary, once there has been something to summarize.
    /// `nil` — not "", which is what an unset stored row decodes to — is what
    /// makes `derivedTitle` fall back rather than show an empty row.
    public var title: String?

    /// Fired when a run reaches a terminal state, so `AppModel` can title the
    /// conversation without the conversation knowing what a title costs.
    public var runDidFinish: (() -> Void)?

    public init(
        id: UUID = UUID(), messages: [ChatMessage] = [],
        transcript: [AgentTranscriptMessage] = [],
        runState: AgentRunState = .idle,
        messageRunIDs: [UUID: UUID] = [:],
        runs: [AgentRunSummary] = [],
        compactionRecords: [AgentCompactionRecord] = [],
        createdAt: Date = .now, updatedAt: Date = .now,
        sortIndex: Double? = nil,
        contextEstimatePublishInterval: Duration = .milliseconds(250)
    ) {
        let contextEstimateTracker = AgentContextEstimateTracker(
            systemPrompt: TermindAgentPolicy.systemPrompt,
            toolSchemaCharacters: 0,
            transcript: transcript,
            attachedCharacters: 0,
            measured: nil
        )
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sortIndex = sortIndex ?? Self.defaultSortIndex(for: updatedAt)
        self.messages = messages
        self.transcript = transcript
        self.messageRunIDs = messageRunIDs
        self.compactionRecords = compactionRecords
        compactions = compactionRecords.map(AgentCompactionMark.init)
        runSummaries = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        reportedRunState = runState
        self.contextEstimatePublishInterval = contextEstimatePublishInterval
        self.contextEstimateTracker = contextEstimateTracker
        contextEstimate = contextEstimateTracker.snapshot()
        contextEstimatePublishCount = 1
    }

    /// The generated summary if there is one, and the opening line until then.
    ///
    /// The fallback is not a placeholder to be replaced on refresh — a title is
    /// generated once, so this is what a conversation shows when the summary
    /// never ran: no model configured, the request failed, or the first reply
    /// has not arrived yet.
    public var derivedTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let title, !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user }) else {
            return String(localized: "New Chat")
        }
        if first.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let attachment = first.contextChips.first?.label ?? first.images.first?.label
        {
            return attachment
        }
        let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    /// User-authored content only. Surface-owned session context is supplied
    /// separately and must never make an otherwise empty composer sendable.
    public var canSendDraft: Bool {
        !composer.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !composer.attachments.isEmpty
    }

    public var isEmpty: Bool { timeline.isEmpty }
    public var isArchived: Bool { archivedAt != nil }

    public var metadata: StoredAgentConversationMetadata {
        StoredAgentConversationMetadata(
            customTitle: customTitle ?? "", isPinned: isPinned,
            sortIndex: sortIndex, archivedAt: archivedAt,
            createdAt: createdAt, updatedAt: updatedAt
        )
    }

    public nonisolated static func defaultSortIndex(for date: Date) -> Double {
        -date.timeIntervalSinceReferenceDate
    }

    public func canEditUserMessage(_ id: UUID) -> Bool {
        guard !isStreaming, !isCompacting, !isArchived, !isHistoryChanging else { return false }
        return transcript.contains { $0.id == id && $0.role == .user && !$0.isCompaction }
    }

    public func canForkAssistantMessage(_ id: UUID) -> Bool {
        guard !isStreaming, !isCompacting, !isArchived, !isHistoryChanging else { return false }
        return transcript.contains { $0.id == id && $0.role == .assistant }
    }

    public func editedUserMessage(_ id: UUID, authoredText: String) -> AgentTranscriptMessage? {
        guard canEditUserMessage(id),
            let target = transcript.firstIndex(where: { $0.id == id })
        else { return nil }
        let original = transcript[target]
        let visible = original.authoredText ?? ContextChip.visiblePrompt(in: original.text)
        let suffix =
            original.text.hasPrefix(visible)
            ? String(original.text.dropFirst(visible.count)) : ""
        return AgentTranscriptMessage(
            role: .user, text: authoredText + suffix, authoredText: authoredText,
            images: original.images, contextAttachments: original.contextAttachments,
            createdAt: .now
        )
    }

    public func editUserMessage(
        _ id: UUID, replacement: AgentTranscriptMessage
    ) -> ComposedUserTurn? {
        guard canEditUserMessage(id),
            let target = transcript.firstIndex(where: { $0.id == id })
        else { return nil }
        let original = transcript[target]
        let removedMessageIDs = Set(transcript[target...].map(\.id))
        let removedRunIDs = Set(removedMessageIDs.compactMap { messageRunIDs[$0] })
        transcript.replaceSubrange(target..., with: [replacement])
        contextEstimateTracker.remove(removedMessageIDs)
        contextEstimateTracker.upsert(replacement)

        if let visibleIndex = messages.firstIndex(where: { $0.id == id }) {
            messages.replaceSubrange(
                visibleIndex...,
                with: [
                    ChatMessage(
                        id: replacement.id, role: .user,
                        text: replacement.authoredText ?? ContextChip.visiblePrompt(in: replacement.text),
                        contextChips: ContextChip.visibleReferences(
                            in: replacement.text, images: replacement.images,
                            contextAttachments: replacement.contextAttachments
                        ), images: replacement.images, createdAt: replacement.createdAt
                    )
                ])
        }
        toolCards.removeAll {
            removedRunIDs.contains($0.invocation.runID)
                || $0.invocation.createdAt >= original.createdAt
        }
        for messageID in removedMessageIDs { messageRunIDs[messageID] = nil }
        for runID in removedRunIDs { runSummaries[runID] = nil }
        plans.removeAll { $0.createdAt >= original.createdAt }
        compactions.removeAll { $0.createdAt >= original.createdAt }
        tasks.removeAll()
        usage = nil
        contextEstimateTracker.setMeasured(nil)
        publishContextEstimateImmediately()
        reportedRunState = .idle
        updatedAt = replacement.createdAt
        if !transcript[..<target].contains(where: { $0.role == .user && !$0.isCompaction }) {
            title = nil
        }
        return ComposedUserTurn(
            id: replacement.id, text: replacement.text,
            authoredText: replacement.authoredText ?? "", images: replacement.images,
            contextAttachments: replacement.contextAttachments
        )
    }

    public func editUserMessage(_ id: UUID, authoredText: String) -> ComposedUserTurn? {
        guard let replacement = editedUserMessage(id, authoredText: authoredText) else {
            return nil
        }
        return editUserMessage(id, replacement: replacement)
    }

    public func forked(
        throughAssistantMessage id: UUID, title forkTitle: String? = nil
    ) -> ConversationModel? {
        guard canForkAssistantMessage(id),
            let selected = transcript.firstIndex(where: { $0.id == id })
        else { return nil }
        var end = selected
        let requiredCalls = Set(transcript[selected].toolCalls.map(\.id))
        if !requiredCalls.isEmpty {
            var cursor = transcript.index(after: selected)
            while cursor < transcript.endIndex, transcript[cursor].role == .tool {
                if let callID = transcript[cursor].toolCallID, requiredCalls.contains(callID) {
                    end = cursor
                }
                cursor = transcript.index(after: cursor)
            }
        }
        let source = Array(transcript[...end])
        var messageIDMap: [UUID: UUID] = [:]
        let cloned = source.map { message -> AgentTranscriptMessage in
            var copy = message
            let newID = UUID()
            messageIDMap[message.id] = newID
            copy.id = newID
            return copy
        }
        let visibleMessages = cloned.compactMap { message -> ChatMessage? in
            guard !message.isCompaction else { return nil }
            switch message.role {
            case .user:
                return ChatMessage(
                    id: message.id, role: .user,
                    text: message.authoredText ?? ContextChip.visiblePrompt(in: message.text),
                    contextChips: ContextChip.visibleReferences(
                        in: message.text, images: message.images,
                        contextAttachments: message.contextAttachments
                    ), images: message.images, createdAt: message.createdAt
                )
            case .assistant:
                guard !message.text.isEmpty || !message.reasoning.isEmpty else { return nil }
                return ChatMessage(
                    id: message.id, role: .assistant, text: message.text,
                    reasoning: message.reasoning,
                    createdAt: message.createdAt
                )
            case .tool: return nil
            }
        }
        let cutoff = transcript[end].createdAt
        let includedMessageIDs = Set(source.map(\.id))
        let includedCards = toolCards.filter { card in
            if let sourceMessageID = card.invocation.sourceMessageID {
                return includedMessageIDs.contains(sourceMessageID)
            }
            return card.invocation.createdAt <= cutoff
        }
        let originalRunIDs = Set(
            source.compactMap { messageRunIDs[$0.id] }
                + includedCards.map(\.invocation.runID)
        )
        let runIDMap = Dictionary(uniqueKeysWithValues: originalRunIDs.map { ($0, UUID()) })
        let clonedMessageRunIDs: [UUID: UUID] = Dictionary(
            uniqueKeysWithValues: source.compactMap { message -> (UUID, UUID)? in
                guard let oldRunID = messageRunIDs[message.id],
                    let newRunID = runIDMap[oldRunID], let newMessageID = messageIDMap[message.id]
                else { return nil }
                return (newMessageID, newRunID)
            }
        )
        let clonedRuns = originalRunIDs.compactMap { oldRunID -> AgentRunSummary? in
            guard var run = runSummaries[oldRunID], let newID = runIDMap[oldRunID]
            else { return nil }
            run.id = newID
            return run
        }
        let clonedCompactions = compactionRecords.compactMap { record -> AgentCompactionRecord? in
            guard let summaryMessageID = messageIDMap[record.summaryMessageID] else { return nil }
            var copy = record
            copy.id = UUID()
            copy.summaryMessageID = summaryMessageID
            // The fork stores only its compact model history, so its summary is
            // the base context rather than a boundary into raw source rows.
            copy.compactedThroughMessageID = nil
            return copy
        }
        let fork = ConversationModel(
            messages: visibleMessages, transcript: cloned, runState: .completed,
            messageRunIDs: clonedMessageRunIDs, runs: clonedRuns,
            compactionRecords: clonedCompactions,
            createdAt: .now, updatedAt: .now
        )
        let resolvedTitle = forkTitle ?? Self.numberedForkTitle(base: derivedTitle, index: 1)
        fork.customTitle = resolvedTitle
        fork.model = model
        fork.permissionMode = permissionMode
        fork.reasoningEffort = reasoningEffort
        fork.isPlanning = isPlanning
        fork.toolCards = includedCards.map { card in
            var copy = card
            copy.invocation.id = UUID()
            copy.invocation.runID = runIDMap[card.invocation.runID] ?? UUID()
            copy.invocation.sourceMessageID = card.invocation.sourceMessageID.flatMap {
                messageIDMap[$0]
            }
            return copy
        }
        return fork
    }

    /// Keeps the disambiguating number visible even when the source title is
    /// already at the persistence limit. A plain `prefix(80)` would trim the
    /// suffix off and leave the fork indistinguishable from its source.
    public nonisolated static func numberedForkTitle(base: String, index: Int) -> String {
        let suffix = " (\(index))"
        return String(base.prefix(max(0, 80 - suffix.count))) + suffix
    }

    /// One collapsible work group per run, keyed by source-message ownership.
    public var workGroups: [AgentWorkGroup] {
        let visibleByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let cardsByRun = Dictionary(
            grouping: toolCards.filter { $0.terminalSuggestion == nil },
            by: { $0.invocation.runID }
        )
        let toolProcessMessageIDs = Set(
            transcript.compactMap { message -> UUID? in
                message.role == .assistant && !message.toolCalls.isEmpty ? message.id : nil
            })
        var processRunIDs: [UUID: UUID] = [:]
        for message in transcript where message.role == .assistant && !message.toolCalls.isEmpty {
            if let runID = messageRunIDs[message.id] {
                processRunIDs[message.id] = runID
            }
        }

        // Reasoning is visible only for the model turn currently in flight.
        // Completed provider summaries remain model-facing data, not UI
        // history, and therefore do not resurrect after restore.
        if let activeReasoningMessageID,
            let runID = messageRunIDs[activeReasoningMessageID]
        {
            processRunIDs[activeReasoningMessageID] = runID
        }

        // Put the generic activity text in the same work slot that reasoning
        // will occupy. Previously the empty assistant row lived outside the
        // work group, so its replacement jumped below a newly inserted header
        // and divider as soon as the first reasoning delta arrived.
        if let activeRunID {
            for message in messages
            where message.role == .assistant && message.isStreaming
                && messageRunIDs[message.id] == activeRunID
            {
                processRunIDs[message.id] = activeRunID
            }
        }

        let stoppedRunIDs = runSummaries.values.compactMap { run in
            run.state == .cancelled ? run.id : nil
        }
        let runIDs = Set(cardsByRun.keys)
            .union(processRunIDs.values)
            .union(stoppedRunIDs)
        return runIDs.compactMap { runID in
            let cards = cardsByRun[runID] ?? []
            let processMessages = processRunIDs.compactMap { messageID, owner -> ChatMessage? in
                guard owner == runID else { return nil }
                return visibleByID[messageID]
            }
            let workHasNonReasoningOutput =
                !cards.isEmpty
                || processMessages.contains { !$0.text.isEmpty }
            let hasVisibleReasoning = processMessages.contains { message in
                message.id == activeReasoningMessageID && !message.reasoning.isEmpty
            }
            let visibleProcess = processMessages.filter { message in
                let livePlaceholder =
                    message.isStreaming && message.text.isEmpty
                    && message.reasoning.isEmpty
                let toolProcess =
                    toolProcessMessageIDs.contains(message.id)
                    && (!message.text.isEmpty
                        || (message.isStreaming && message.reasoning.isEmpty))
                // Working belongs to the Work as a whole. Reasoning does not
                // consume this slot: a later empty turn may still be replaced
                // by its next reasoning block. Any non-reasoning output does.
                return
                    (livePlaceholder
                    && !hasVisibleReasoning
                    && !workHasNonReasoningOutput)
                    || toolProcess
            }
            let groupableCards = cards.filter {
                $0.descriptor.presentation?.groupsWithAdjacentTools != false
            }
            let hasUnfinishedGroupableTool = groupableCards.contains {
                !$0.state.isTerminal
            }
            let latestToolReasoning =
                processMessages
                .sorted { $0.createdAt < $1.createdAt }
                .reversed()
                .compactMap { message -> AgentToolReasoning? in
                    guard let markdown = message.reasoning.last?.text,
                        !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    else { return nil }
                    return AgentToolReasoning(
                        sourceMessageID: message.id,
                        markdown: markdown
                    )
                }
                .first
            // Once there is a tool surface to carry it, reasoning becomes a
            // transient title instead of a separate structural row. Before the
            // atomic batch is published it remains visible on its own.
            let reasoningItems =
                !hasUnfinishedGroupableTool
                ? processMessages.flatMap { message -> [AgentWorkItem] in
                    guard message.id == activeReasoningMessageID else { return [] }
                    return message.reasoning.map(AgentWorkItem.reasoning)
                }
                : []
            let activeReasoningBlockID = processMessages.first(where: {
                $0.id == activeReasoningMessageID && $0.isStreaming && $0.text.isEmpty
            })?.reasoning.last?.id
            var items =
                reasoningItems + visibleProcess.map(AgentWorkItem.message)
                + cards.map(AgentWorkItem.tool)
            items.sort {
                if $0.orderedAt != $1.orderedAt { return $0.orderedAt < $1.orderedAt }
                switch ($0, $1) {
                case (.reasoning, .message), (.reasoning, .tool), (.reasoning, .tools): return true
                case (.message, .reasoning), (.tool, .reasoning), (.tools, .reasoning): return false
                case (.message, .tool), (.message, .tools): return true
                case (.tool, .message), (.tools, .message): return false
                default: return $0.id.uuidString < $1.id.uuidString
                }
            }
            items = Self.groupRunTools(
                in: items,
                runID: runID,
                reasoning: hasUnfinishedGroupableTool ? latestToolReasoning : nil
            )
            let stored = runSummaries[runID]
            // A user stop is useful transcript state even when it interrupted a
            // direct response before any tool or process item was produced.
            guard !items.isEmpty || stored?.state == .cancelled else { return nil }

            // The work row follows the clock of the first thing it actually
            // presents. A stopped direct answer has no work item, so its stop
            // event is the row's place in the timeline.
            let orderedAt =
                items.first?.orderedAt
                ?? stored?.finishedAt
                ?? stored?.startedAt
                ?? .now
            let anchorID = messages.first(where: { $0.createdAt >= orderedAt })?.id
            let answerAt = messages.last(where: {
                $0.role == .assistant
                    && !$0.text.isEmpty
                    && messageRunIDs[$0.id] == runID
                    && processRunIDs[$0.id] == nil
                    && $0.createdAt < orderedAt
            })?.createdAt
            let fallbackState: AgentRunState =
                cards.allSatisfy {
                    $0.state == .completed
                } ? .completed : .interrupted
            var run =
                stored
                ?? AgentRunSummary(
                    id: runID, state: fallbackState,
                    startedAt: items.first?.orderedAt ?? orderedAt,
                    finishedAt: items.last?.orderedAt
                )
            if activeRunID == runID { run.state = runState }
            return AgentWorkGroup(
                run: run, items: items, orderedAt: orderedAt,
                anchorMessageID: anchorID, appearsAfterAnswer: answerAt != nil,
                activeReasoningBlockID: activeReasoningBlockID
            )
        }.sorted { $0.orderedAt < $1.orderedAt }
    }

    /// Produces one stable batch for every grouping-enabled tool in the run.
    /// Reasoning, provider-turn boundaries and ordinary process messages remain
    /// in chronological order but no longer flush the tool collection. Tools
    /// that explicitly opt out keep their direct row.
    private static func groupRunTools(
        in items: [AgentWorkItem],
        runID: UUID,
        reasoning: AgentToolReasoning?
    ) -> [AgentWorkItem] {
        let batched = items.compactMap { item -> AgentToolCard? in
            guard case .tool(let card) = item,
                card.descriptor.presentation?.groupsWithAdjacentTools != false
            else { return nil }
            return card
        }
        guard !batched.isEmpty else { return items }

        var grouped: [AgentWorkItem] = []
        var insertedBatch = false
        for item in items {
            if case .tool(let card) = item {
                if card.descriptor.presentation?.groupsWithAdjacentTools == false {
                    grouped.append(.tool(card))
                } else if !insertedBatch {
                    grouped.append(
                        .tools(
                            AgentToolBatch(
                                cards: batched,
                                runID: runID,
                                reasoning: reasoning
                            )))
                    insertedBatch = true
                }
            } else {
                grouped.append(item)
            }
        }
        return grouped
    }

    /// Messages and run-scoped work in the order the reader experienced them.
    public var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        let groups = workGroups
        let groupedProcessIDs: Set<UUID> = Set(
            groups.flatMap { group -> [UUID] in
                group.items.compactMap { item -> UUID? in
                    guard case .message(let message) = item else { return nil }
                    return message.id
                }
            })
        var emittedGroups = Set<UUID>()
        for message in messages {
            for group in groups where group.anchorMessageID == message.id {
                items.append(.work(group))
                emittedGroups.insert(group.id)
            }
            if groupedProcessIDs.contains(message.id) { continue }
            // A turn that only called tools has no text to show, and an empty
            // bubble reads as the model having said nothing. While it is still
            // streaming it stays only until this turn receives reasoning; that
            // live text then owns the activity treatment until turnFinished.
            guard
                message.role != .assistant || !message.text.isEmpty
                    || (message.isStreaming && message.reasoning.isEmpty)
            else { continue }
            items.append(.message(message))
        }
        items += groups.filter { !emittedGroups.contains($0.id) }.map(TimelineItem.work)
        let commands = toolCards.compactMap(\.terminalSuggestion)
        guard
            !commands.isEmpty || !plans.isEmpty || !compactions.isEmpty
                || compactionActivity != nil
        else {
            return items
        }
        // Merged by time rather than woven into the loop above. A plan ends its
        // run and a compaction happens between runs, so there are never many of
        // either, and two more cursors inside that loop would be two more things
        // to keep right for no gain.
        var extra =
            commands.map(TimelineItem.command)
            + plans.map(TimelineItem.plan)
            + compactions.map(TimelineItem.compaction)
        if let compactionActivity { extra.append(.compactionActivity(compactionActivity)) }
        return (items + extra).sorted {
            $0.orderedAt == $1.orderedAt
                ? $0.sortRank < $1.sortRank : $0.orderedAt < $1.orderedAt
        }
    }

    // MARK: - Compaction

    /// What a compaction would summarize, or `nil` when there is not enough
    /// history to be worth it.
    public func compactionSpan(
        keepRecentTokens: Int = AgentCompaction.defaultKeepRecentTokens
    ) -> (summarize: [AgentTranscriptMessage], cut: Int)? {
        guard
            let cut = AgentCompaction.cutIndex(
                in: transcript, keepRecentTokens: keepRecentTokens
            )
        else { return nil }
        return (Array(transcript[..<cut]), cut)
    }

    public func beginCompaction() {
        isCompacting = true
        compactionActivity = AgentCompactionActivity(state: .running)
    }

    public func endCompaction() {
        isCompacting = false
        compactionActivity = nil
    }

    public func failCompaction(_ reason: String) {
        isCompacting = false
        if var activity = compactionActivity {
            activity.state = .failed(reason)
            compactionActivity = activity
        } else {
            compactionActivity = AgentCompactionActivity(state: .failed(reason))
        }
    }

    /// Builds the durable record without changing the conversation. AppModel
    /// persists this value before applying it, so a failed save cannot leave
    /// memory and disk describing different contexts.
    public func prepareCompaction(summary: String, cut: Int) -> AgentCompactionRecord? {
        guard cut > 0, cut <= transcript.count else { return nil }
        let summarized = transcript[..<cut]
        let summarizedTokens = summarized.reduce(0) {
            $0
                + AgentContextEstimator.tokens(
                    inCharacters: AgentContextEstimator.characterUnits(in: $1.text)
                )
        }
        let boundary =
            summarized.reversed().first(where: { !$0.isCompaction })?.id
            ?? compactionRecords.last?.compactedThroughMessageID
        return AgentCompactionRecord(
            compactedThroughMessageID: boundary,
            sequence: (compactionRecords.map(\.sequence).max() ?? -1) + 1,
            summary: summary,
            summarizedTokens: summarizedTokens,
            keptTokens: AgentContextEstimator.tokens(
                inCharacters: AgentContextEstimator.characterUnits(in: summary)
            ),
            displayAnchor: transcript[cut - 1].createdAt
        )
    }

    /// Replaces everything before `cut` with the already-persisted summary.
    ///
    /// `transcript` — what the model is sent — is rewritten. `messages` — what
    /// the reader sees — is not: a marker is added instead, so the conversation
    /// stays scrollable and nothing the user wrote disappears. That is the same
    /// rule `AgentContextPipeline` states for every other transform.
    public func applyCompaction(_ record: AgentCompactionRecord, cut: Int) {
        precondition(cut > 0 && cut <= transcript.count)
        let replacement = record.summaryMessage
        let removedIDs = transcript[..<cut].map(\.id)
        transcript.replaceSubrange(..<cut, with: [replacement])
        contextEstimateTracker.remove(removedIDs)
        contextEstimateTracker.upsert(replacement)
        compactionRecords.append(record)
        compactions.append(AgentCompactionMark(record))
        // The gauge is measuring a context that no longer exists. Dropping it
        // rather than scaling it means the next turn reports a real number and
        // until then the estimate is shown as an estimate.
        usage = nil
        contextEstimateTracker.setMeasured(nil)
        publishContextEstimateImmediately()
    }

    /// Convenience for focused model tests that do not exercise persistence.
    @discardableResult
    public func applyCompaction(summary: String, cut: Int) -> AgentCompactionRecord? {
        guard let record = prepareCompaction(summary: summary, cut: cut) else { return nil }
        applyCompaction(record, cut: cut)
        return record
    }

    /// Records what the user decided about a plan.
    ///
    /// Implementing turns plan mode off, because that is what the decision
    /// means: the next run is the one that acts. Keeping the mode on after
    /// "Implement" would refuse every tool the plan asked for.
    public func resolvePlan(_ id: AgentPlan.ID, as outcome: AgentPlan.Outcome) {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[index].outcome = outcome
        if outcome == .implemented { isPlanning = false }
    }

    /// What starting the implementation run should send.
    ///
    /// The plan itself is already in `transcript` — `present_plan` returned it —
    /// so this is a pointer, not a copy. Naming the scratch path lets the model
    /// re-read the exact text rather than work from what it remembers writing.
    public static func implementationPrompt(for plan: AgentPlan) -> String {
        String(
            localized: """
                Implement the plan you presented ("\(plan.title)", drafted at \
                \(plan.scratchPath)). Follow it; if something you find contradicts it, say so \
                before departing from it.
                """
        )
    }

    public func attach(_ chip: ContextChip) {
        guard
            !composer.attachments.contains(where: {
                if let image = chip.image, let existing = $0.image {
                    return existing.data == image.data
                }
                return $0.kind == chip.kind && $0.content == chip.content
            })
        else { return }
        composer.attachments.append(chip)
        refreshAttachedContextEstimate()
    }

    public func detach(_ id: ContextChip.ID) {
        composer.attachments.removeAll { $0.id == id }
        refreshAttachedContextEstimate()
    }

    public func beginAttachmentImport(label: String) -> PendingContextAttachment? {
        guard
            composer.attachments.count + composer.pendingAttachments.count
                < ContextAttachmentLoading.maximumAttachments
        else {
            composer.attachmentImportError = String(
                localized: "A message can include at most 20 attachments."
            )
            return nil
        }
        let pending = PendingContextAttachment(label: label)
        composer.pendingAttachments.append(pending)
        return pending
    }

    public func importAttachmentFiles(_ urls: [URL]) {
        for url in urls.prefix(ContextAttachmentLoading.maximumAttachments) {
            guard let pending = beginAttachmentImport(label: url.lastPathComponent) else { break }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let chip = try await attachmentLoader.file(url)
                    finishAttachmentImport(pending.id, with: chip)
                } catch is CancellationError {
                    cancelAttachmentImport(pending.id)
                } catch {
                    failAttachmentImport(
                        pending.id,
                        message: "\(url.lastPathComponent): \(error.localizedDescription)"
                    )
                }
                attachmentImportTasks[pending.id] = nil
            }
            attachmentImportTasks[pending.id] = task
        }
    }

    public func importAttachmentImages(_ images: [Data], label: String) {
        for data in images.prefix(ContextAttachmentLoading.maximumAttachments) {
            guard let pending = beginAttachmentImport(label: label) else { break }
            let task = Task { [weak self] in
                guard let self else { return }
                do {
                    let chip = try await attachmentLoader.image(data, label)
                    finishAttachmentImport(pending.id, with: chip)
                } catch is CancellationError {
                    cancelAttachmentImport(pending.id)
                } catch {
                    failAttachmentImport(pending.id, message: error.localizedDescription)
                }
                attachmentImportTasks[pending.id] = nil
            }
            attachmentImportTasks[pending.id] = task
        }
    }

    public func finishAttachmentImport(_ id: PendingContextAttachment.ID, with chip: ContextChip) {
        guard composer.pendingAttachments.contains(where: { $0.id == id }) else { return }
        composer.pendingAttachments.removeAll { $0.id == id }
        attach(chip)
    }

    public func failAttachmentImport(_ id: PendingContextAttachment.ID, message: String) {
        guard composer.pendingAttachments.contains(where: { $0.id == id }) else { return }
        composer.pendingAttachments.removeAll { $0.id == id }
        composer.attachmentImportError = [composer.attachmentImportError, message]
            .compactMap { $0 }.joined(separator: "\n")
    }

    public func cancelAttachmentImport(_ id: PendingContextAttachment.ID) {
        attachmentImportTasks[id]?.cancel()
        attachmentImportTasks[id] = nil
        composer.pendingAttachments.removeAll { $0.id == id }
    }

    /// Records a local user turn. Agent-backed composers use AppModel's runtime
    /// path; the sidebar promotion flow uses this before starting that run.
    public func sendDraft() {
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendDraft else { return }
        appendUserTurn(text)
        composer.draft = ""
    }

    /// Adds one user turn to both the visible transcript and the model-facing
    /// one, folding attachments into only the latter, and hands back the text
    /// that actually went.
    ///
    /// The caller must start its run with the *returned* string. The run request
    /// carries the prompt separately and `AgentRuntime` appends it to its own
    /// snapshot, so passing the pre-fold text there would send the model a turn
    /// that does not match the one in `transcript` — and `priorMessages` must
    /// stop short of it either way, see `pendingPriorMessages`.
    ///
    /// Attachments are consumed, not kept: they belong to this message, they are
    /// in the transcript from here on, and the pill going away is how the user
    /// sees that the payload was sent.
    @discardableResult
    public func appendUserTurn(_ text: String) -> String {
        appendUserTurnContent(text).text
    }

    public struct ComposedUserTurn: Sendable {
        public var id: UUID
        public var text: String
        public var authoredText: String
        public var images: [AgentImageAttachment]
        public var contextAttachments: [AgentContextAttachment]

        public init(
            id: UUID, text: String, authoredText: String, images: [AgentImageAttachment],
            contextAttachments: [AgentContextAttachment]
        ) {
            self.id = id
            self.text = text
            self.authoredText = authoredText
            self.images = images
            self.contextAttachments = contextAttachments
        }
    }

    @discardableResult
    public func appendUserTurnContent(_ text: String, contextSnapshot: AgentTurnContextSnapshot? = nil)
        -> ComposedUserTurn
    {
        let composed = composed(text)
        let messageID = UUID()
        let contextChips = composer.attachments.map {
            ContextChipReference(
                id: $0.id, kind: $0.kind, label: $0.label,
                attachment: $0.contextAttachment
            )
        }
        composer.attachments.removeAll()
        composer.armedSkillName = nil
        refreshAttachedContextEstimate()
        messages.append(
            ChatMessage(
                id: messageID, role: .user, text: text,
                contextChips: contextChips, images: composed.images
            )
        )
        transcript.append(
            AgentTranscriptMessage(
                id: messageID, role: .user, text: composed.text,
                authoredText: text, images: composed.images,
                contextAttachments: composed.contextAttachments, contextSnapshot: contextSnapshot
            )
        )
        if let message = transcript.last {
            contextEstimateTracker.upsert(message)
            publishContextEstimateImmediately()
        }
        updatedAt = .now
        return ComposedUserTurn(
            id: messageID, text: composed.text, authoredText: text, images: composed.images,
            contextAttachments: composed.contextAttachments
        )
    }

    /// Renders attachments into the model-facing message body. The visible
    /// `ChatMessage` deliberately keeps only the prompt: extracted documents
    /// and pasted text can be hundreds of thousands of characters and do not
    /// belong in a Markdown bubble.
    private func composed(_ text: String) -> ComposedUserTurn {
        let skillDirective = composer.armedSkillName.map { name in
            """
            <use_skill name="\(name)">
            The user asked for this skill by name. Load it with load_skill before answering, and \
            follow it.
            </use_skill>
            """
        }
        guard !composer.attachments.isEmpty || skillDirective != nil else {
            return ComposedUserTurn(
                id: UUID(), text: text, authoredText: text, images: [],
                contextAttachments: []
            )
        }
        let blocks = composer.attachments.compactMap { chip -> String? in
            guard chip.image == nil else { return nil }
            // A label can be a filename, and a filename can contain a quote —
            // which would close the attribute and leave the block malformed.
            let label = chip.label.replacingOccurrences(of: "\"", with: "'")
            return """
                <\(chip.kind.blockName) label="\(label)">
                \(chip.content)
                </\(chip.kind.blockName)>
                """
        }
        // The directive rides `text` and not `authoredText`, exactly as the
        // attachment blocks do. What the user typed is what the bubble shows,
        // what message editing reopens, and what the title generator reads; the
        // model gets the instruction as well.
        return ComposedUserTurn(
            id: UUID(),
            text: ([text] + blocks + [skillDirective].compactMap { $0 })
                .joined(separator: "\n\n"),
            authoredText: text,
            images: composer.attachments.compactMap(\.image),
            contextAttachments: composer.attachments.compactMap(\.contextAttachment)
        )
    }

    /// The history to replay for a run whose prompt is the last user turn.
    public var pendingPriorMessages: [AgentTranscriptMessage] {
        guard let last = transcript.lastIndex(where: { $0.role == .user }),
            last == transcript.index(before: transcript.endIndex)
        else { return transcript }
        return Array(transcript[..<last])
    }

    /// Takes ownership of a run before it can emit its first event. Keeping the
    /// runtime and its consumer together prevents an immediately-completing
    /// provider response from racing the UI attachment path.
    public private(set) var activeContextSnapshot: AgentTurnContextSnapshot?

    public func start(runtime: AgentRuntime, request: AgentRunRequest) {
        activeContextSnapshot = request.contextSnapshot
        if let index = transcript.firstIndex(where: { $0.id == request.promptID }) {
            transcript[index].contextSnapshot = request.contextSnapshot
            contextEstimateTracker.upsert(transcript[index])
        }
        self.runtime = runtime
        reportedRunState = .running
        runtimeGeneration &+= 1
        let generation = runtimeGeneration
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard !Task.isCancelled, self?.runtimeGeneration == generation else { return }
            let events = await runtime.start(request)
            if Task.isCancelled || self?.runtimeGeneration != generation { await runtime.cancel() }
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    /// Retains the ordered event consumer until the cancellation snapshot is durable.
    public func stopAndWait() async {
        guard let runtime else {
            stop()
            return
        }
        let consumer = eventTask
        runtimeGeneration &+= 1
        await runtime.cancel()
        await consumer?.value
        stop()
    }

    public func stop() {
        runtimeGeneration &+= 1
        settleStreamingPresentation(for: activeRunID)
        publishAllStagedTools()
        for index in toolCards.indices where toolCards[index].state == .running {
            toolCards[index].state = .interrupted
        }
        eventTask?.cancel()
        eventTask = nil
        // Read the runtime *before* releasing it. `Task { await runtime?… }`
        // resolves the property when the task runs, which is after this method
        // has already set it to nil — so the run kept executing tools with
        // nobody listening.
        if let runtime { Task { await runtime.cancel() } }
        runtime = nil
        if !reportedRunState.isTerminal {
            reportedRunState = .cancelled
            // The event consumer was just cancelled, so it cannot receive the
            // runtime's eventual finish event. Freeze the visible elapsed time
            // here instead of letting a stopped run keep counting forever.
            if let activeRunID, var summary = runSummaries[activeRunID] {
                summary.state = .cancelled
                summary.finishedAt = .now
                runSummaries[activeRunID] = summary
                self.activeRunID = nil
            }
        }
        returnAllSteeringToDraft()
    }

    /// Queues the draft for the running agent instead of starting a second run.
    ///
    /// Nothing reaches `messages` or `transcript` here. A bubble posted at the
    /// keystroke sits above the assistant text that actually preceded it, and
    /// `transcript` is replayed as the next run's history — so the model would
    /// later be shown a conversation that never happened. The bubble appears
    /// when the runtime reports the message delivered, which is where the model
    /// really saw it.
    public func submitSteeringDraft(context: SessionContext = .none, includesTerminalSuggestion: Bool = false) {
        let text = composer.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSendDraft, let runtime else { return }
        let composed = composed(text)
        var snapshot = activeContextSnapshot?.withSessionContext(context.modelContext)
        snapshot?.toolAvailability = ["terminal_suggest": includesTerminalSuggestion]
        let pending = PendingSteeringMessage(
            draft: text, attachments: composer.attachments,
            message: AgentTranscriptMessage(
                role: .user, text: composed.text, authoredText: text,
                images: composed.images, contextAttachments: composed.contextAttachments,
                contextSnapshot: snapshot
            )
        )
        pendingSteering.append(pending)
        composer.attachments.removeAll()
        refreshAttachedContextEstimate()
        composer.draft = ""
        Task { [weak self] in
            guard await runtime.steer(pending.message) == false else { return }
            // The run ended between the keystroke and this hop. Everything
            // still queued is undeliverable, not just this one — and returning
            // the whole queue at once is also what keeps the words in the order
            // they were typed, which racing hops resolving one at a time would
            // not.
            self?.returnAllSteeringToDraft()
        }
    }

    /// Hands one queued message back to the composer.
    ///
    /// Called by the ✕ on a queued row, and by every path that ends a run with
    /// something still undelivered. Dropping the text instead would be the
    /// second time the same words disappeared without being sent.
    public func returnSteeringToDraft(_ id: AgentTranscriptMessage.ID) {
        guard let index = pendingSteering.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingSteering.remove(at: index)
        composer.draft = [pending.draft, composer.draft]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        for chip in pending.attachments { attach(chip) }
    }

    /// Reversed because each entry is put back *above* the draft, so walking
    /// the queue backwards is what leaves it in the order it was typed.
    private func returnAllSteeringToDraft() {
        for pending in pendingSteering.reversed() { returnSteeringToDraft(pending.id) }
    }

    /// Owns the approval queue.
    ///
    /// `AgentApprovalBroker` both publishes `approvalRequested` and calls this,
    /// and the two used to write the same slot, which made the duplication
    /// invisible. Against a queue it would not be: `handle` deliberately only
    /// moves the card's state, and enqueueing happens here — on the path that
    /// holds the continuation and can therefore actually answer.
    public func requestApproval(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        // The approval callback can arrive before the channel drains toolProposed.
        // Stage the same identity now so a direct user response has a card to update.
        stageTool(request.invocation, descriptor: request.descriptor)
        // Inserted by when the call was *planned*, not by when it got here. A
        // parallel batch races to this queue, so appending put the cards in
        // whichever order the scheduler happened to resolve — the same two
        // calls could be presented either way round on two runs. Planning is
        // sequential, so `createdAt` is the model's own order, and asking about
        // the second thing first is a needless surprise in the one place the
        // user is being asked to authorize something.
        let index = pendingApprovals.firstIndex {
            $0.invocation.createdAt > request.invocation.createdAt
        }
        pendingApprovals.insert(request, at: index ?? pendingApprovals.endIndex)
        setToolState(request.invocation.id, .waitingForApproval)
        return await withCheckedContinuation { approvalWaiters[request.id] = $0 }
    }

    public func respondToApproval(_ requestID: UUID, allow: Bool) {
        guard pendingApprovals.first?.id == requestID else { return }
        let request = pendingApprovals.removeFirst()
        let decision: AgentApprovalDecision =
            allow
            ? .allow : .deny(String(localized: "The user denied this action."))
        if !allow { setToolState(request.invocation.id, .denied) }
        approvalWaiters.removeValue(forKey: request.id)?.resume(returning: decision)
    }

    public func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inputWaiters[request.id] = continuation
                present(request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelUserInput(request.id)
            }
        }
    }

    public func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                sshAuthenticationWaiters[request.id] = $0
                let index = pendingSSHAuthentications.firstIndex {
                    $0.createdAt > request.createdAt
                }
                pendingSSHAuthentications.insert(
                    request, at: index ?? pendingSSHAuthentications.endIndex
                )
                setToolState(request.invocationID, .waitingForUser)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSSHAuthentication(request.id) }
        }
    }

    public func respondToSSHAuthentication(_ response: AgentSSHAuthenticationResponse) {
        guard !pendingSSHAuthentications.isEmpty else { return }
        let request = pendingSSHAuthentications.removeFirst()
        setToolState(request.invocationID, .running)
        sshAuthenticationWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    public func requestSSHHostKeyConfirmation(
        _ request: AgentSSHHostKeyRequest
    ) async -> AgentSSHHostKeyResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation {
                sshHostKeyWaiters[request.id] = $0
                let index = pendingSSHHostKeys.firstIndex {
                    $0.createdAt > request.createdAt
                }
                pendingSSHHostKeys.insert(
                    request, at: index ?? pendingSSHHostKeys.endIndex
                )
                setToolState(request.invocationID, .waitingForUser)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelSSHHostKey(request.id) }
        }
    }

    public func respondToSSHHostKey(_ response: AgentSSHHostKeyResponse) {
        guard !pendingSSHHostKeys.isEmpty else { return }
        let request = pendingSSHHostKeys.removeFirst()
        setToolState(request.invocationID, .running)
        sshHostKeyWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    private func cancelSSHAuthentication(_ id: UUID) {
        guard let index = pendingSSHAuthentications.firstIndex(where: { $0.id == id })
        else { return }
        pendingSSHAuthentications.remove(at: index)
        sshAuthenticationWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

    private func cancelSSHHostKey(_ id: UUID) {
        guard let index = pendingSSHHostKeys.firstIndex(where: { $0.id == id }) else { return }
        pendingSSHHostKeys.remove(at: index)
        sshHostKeyWaiters.removeValue(forKey: id)?.resume(returning: .deny)
    }

    /// Puts a question on screen. The queue path uses it, and so does any
    /// caller that wants the card without a run behind it.
    public func present(_ request: AgentUserInputRequest) {
        let previousHead = pendingUserInputs.first?.id
        let index = pendingUserInputs.firstIndex { $0.createdAt > request.createdAt }
        pendingUserInputs.insert(request, at: index ?? pendingUserInputs.endIndex)
        // Only the head is being answered, so only the head's drafts exist. A
        // queued question gets a blank sheet when it reaches the front.
        if pendingUserInputs.first?.id != previousHead {
            clearUserInputDrafts()
            scheduleUserInputTimeout()
        }
    }

    public func userInputDraft(for questionID: String) -> AgentUserInputDraft {
        userInputDrafts[questionID] ?? AgentUserInputDraft()
    }

    /// Whether this one question has been answered. Skipping is allowed, so
    /// this drives a count rather than a validation error.
    public func isUserInputAnswered(_ question: AgentUserQuestion) -> Bool {
        switch question.kind {
        case .secret: return !secretInputDraft.isEmpty
        default:
            let draft = userInputDraft(for: question.id)
            return !draft.selection.isEmpty || !draft.trimmedText.isEmpty
        }
    }

    public var answeredUserInputCount: Int {
        pendingUserInput?.questions.filter(isUserInputAnswered).count ?? 0
    }

    public var currentUserInputQuestion: AgentUserQuestion? {
        guard let questions = pendingUserInput?.questions,
            questions.indices.contains(currentUserInputQuestionIndex)
        else { return nil }
        return questions[currentUserInputQuestionIndex]
    }

    public var canAdvanceUserInput: Bool {
        guard let question = currentUserInputQuestion else { return false }
        return isUserInputAnswered(question) || skippedUserInputQuestionIDs.contains(question.id)
    }

    public var canSubmitUserInput: Bool {
        guard let request = pendingUserInput else { return false }
        return currentUserInputQuestionIndex == request.questions.count - 1 && canAdvanceUserInput
    }

    public var canSkipUserInputQuestion: Bool {
        guard let question = currentUserInputQuestion else { return false }
        if case .secret = question.kind { return false }
        return true
    }

    public func toggleUserInputOption(_ optionID: String, in questionID: String) {
        guard case .choice(let choice)? = question(questionID)?.kind else { return }
        var draft = userInputDraft(for: questionID)
        if choice.allowsMultipleAnswers {
            if draft.selection.contains(optionID) {
                draft.selection.remove(optionID)
            } else {
                draft.selection.insert(optionID)
            }
        } else {
            draft.selection = draft.selection.contains(optionID) ? [] : [optionID]
            // One answer means one answer: a half-typed "something else" left
            // sitting under a chosen radio would be a second, contradicting one.
            draft.text = ""
        }
        userInputDrafts[questionID] = draft
        skippedUserInputQuestionIDs.remove(questionID)
    }

    /// Handles an option click from the question card. A radio choice is a
    /// complete answer, so it advances immediately; checkboxes remain a draft
    /// until the user explicitly confirms the set.
    public func answerUserInputOption(_ optionID: String, in questionID: String) {
        guard case .choice(let choice)? = question(questionID)?.kind else { return }
        guard !choice.allowsMultipleAnswers else {
            toggleUserInputOption(optionID, in: questionID)
            return
        }

        var draft = userInputDraft(for: questionID)
        draft.selection = [optionID]
        draft.text = ""
        userInputDrafts[questionID] = draft
        skippedUserInputQuestionIDs.remove(questionID)
        advanceUserInputQuestion()
    }

    /// The other half of that rule — typing clears the radio it would otherwise
    /// silently disagree with. Left alone in a multi-answer question, where the
    /// two are additive rather than exclusive.
    public func setUserInputCustomAnswer(_ text: String, for questionID: String) {
        var draft = userInputDraft(for: questionID)
        draft.text = text
        if case .choice(let choice)? = question(questionID)?.kind,
            !choice.allowsMultipleAnswers, !text.isEmpty
        {
            draft.selection.removeAll()
        }
        userInputDrafts[questionID] = draft
        if !draft.selection.isEmpty || !draft.trimmedText.isEmpty {
            skippedUserInputQuestionIDs.remove(questionID)
        }
    }

    public func advanceUserInputQuestion() {
        guard let request = pendingUserInput, canAdvanceUserInput else { return }
        if currentUserInputQuestionIndex == request.questions.count - 1 {
            submitUserInput()
        } else {
            currentUserInputQuestionIndex += 1
        }
    }

    public func previousUserInputQuestion() {
        guard currentUserInputQuestionIndex > 0 else { return }
        currentUserInputQuestionIndex -= 1
    }

    public func skipUserInputQuestion() {
        guard let question = currentUserInputQuestion, canSkipUserInputQuestion else { return }
        userInputDrafts[question.id] = AgentUserInputDraft()
        skippedUserInputQuestionIDs.insert(question.id)
        advanceUserInputQuestion()
    }

    public func submitUserInput() {
        guard let request = pendingUserInput, canSubmitUserInput else { return }
        let answers = request.questions.compactMap { question -> AgentUserInputAnswer? in
            guard isUserInputAnswered(question) else { return nil }
            let draft = userInputDraft(for: question.id)
            switch question.kind {
            case .secret:
                return AgentUserInputAnswer(
                    questionID: question.id, value: .secret(secretInputDraft)
                )
            case .text:
                return AgentUserInputAnswer(questionID: question.id, value: .text(draft.text))
            case .choice(let choice):
                let custom = draft.trimmedText
                return AgentUserInputAnswer(
                    questionID: question.id,
                    // Ordered by the question, not by whatever order the user
                    // clicked in — the model wrote the list and reads the
                    // answer against it.
                    value: .choice(
                        selectedIDs: choice.options.map(\.id).filter(draft.selection.contains),
                        custom: custom.isEmpty ? nil : custom
                    )
                )
            }
        }
        advanceUserInput()
        inputWaiters.removeValue(forKey: request.id)?.resume(returning: .answered(answers))
    }

    public func cancelUserInput() {
        guard let request = pendingUserInput else { return }
        cancelUserInput(request.id)
    }

    private func question(_ id: String) -> AgentUserQuestion? {
        pendingUserInput?.questions.first { $0.id == id }
    }

    /// Retires the answered question and hands a clean sheet to the next one.
    private func advanceUserInput() {
        userInputTimeoutTask?.cancel()
        userInputTimeoutTask = nil
        if !pendingUserInputs.isEmpty { pendingUserInputs.removeFirst() }
        clearUserInputDrafts()
        scheduleUserInputTimeout()
    }

    /// Removes one request by identity. Cancellation may target a queued call,
    /// while timeout only targets the visible head; neither is allowed to
    /// retire whichever request happens to be current by the time it arrives.
    private func cancelUserInput(_ id: UUID) {
        guard let index = pendingUserInputs.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = index == pendingUserInputs.startIndex
        pendingUserInputs.remove(at: index)
        if wasCurrent {
            userInputTimeoutTask?.cancel()
            userInputTimeoutTask = nil
            clearUserInputDrafts()
            scheduleUserInputTimeout()
        }
        inputWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

    private func scheduleUserInputTimeout() {
        userInputTimeoutTask?.cancel()
        guard let request = pendingUserInput else {
            userInputTimeoutTask = nil
            userInputDeadline = nil
            return
        }
        let deadline = questionClockNow().advanced(by: request.timeout)
        userInputDeadline = deadline
        let sleep = questionClockSleep
        userInputTimeoutTask = Task { [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                return
            }
            self?.timeOutUserInput(request.id)
        }
    }

    private func timeOutUserInput(_ id: UUID) {
        guard pendingUserInput?.id == id else { return }
        advanceUserInput()
        inputWaiters.removeValue(forKey: id)?.resume(returning: .timedOut)
    }

    private func clearUserInputDrafts() {
        secretInputDraft = ""
        userInputDrafts = [:]
        currentUserInputQuestionIndex = 0
        skippedUserInputQuestionIDs = []
    }

    private func applyMessageDelta(_ text: String, to id: AgentTranscriptMessage.ID) {
        guard !text.isEmpty else { return }
        contextEstimateTracker.appendStreamingText(text, to: id)
        scheduleContextEstimatePublish()
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text += text
            if !messages[index].isStreaming { messages[index].isStreaming = true }
        } else {
            messages.append(
                ChatMessage(id: id, role: .assistant, text: text, isStreaming: true)
            )
        }
    }

    private func applyReasoningDelta(_ text: String, to id: AgentTranscriptMessage.ID) {
        guard !text.isEmpty,
            let index = messages.firstIndex(where: { $0.id == id })
        else { return }
        if messages[index].reasoning.isEmpty {
            messages[index].reasoning.append(
                AgentReasoningBlock(text: text, createdAt: messages[index].createdAt)
            )
        } else {
            let last = messages[index].reasoning.index(
                before: messages[index].reasoning.endIndex
            )
            messages[index].reasoning[last].text += text
        }
        if !messages[index].isStreaming { messages[index].isStreaming = true }
    }

    /// Ends presentation that only makes sense while a provider stream is
    /// live. A cancelled turn never emits `messageFinished`, so without this
    /// explicit cleanup its empty placeholder keeps drawing Working forever
    /// (and a partial answer keeps its streaming caret) after the run ends.
    ///
    /// There can only be one active run in a conversation. `nil` is therefore
    /// the safe fallback for a terminal event whose run boundary was missed:
    /// settle every orphaned streaming message rather than leave the UI live.
    private func settleStreamingPresentation(for runID: UUID?) {
        if activeReasoningMessageID != nil { activeReasoningMessageID = nil }
        for index in messages.indices where messages[index].isStreaming {
            guard runID == nil || messageRunIDs[messages[index].id] == runID else {
                continue
            }
            messages[index].isStreaming = false
        }
        contextEstimateTracker.clearStreamingText()
        publishContextEstimateImmediately()
    }

    public func handle(_ event: AgentEvent) {
        switch event {
        case .runState(let state):
            if state.isTerminal { publishAllStagedTools() }
            reportedRunState = state
            if state.isTerminal { settleStreamingPresentation(for: activeRunID) }
            if state.isTerminal {
                returnAllSteeringToDraft()
                runDidFinish?()
            }
        // Run and turn boundaries are for readers that group by turn. The
        // conversation draws a flat timeline, so it has nothing to do with
        // them — but they are listed rather than swept into a `default` so
        // adding an event stays a compile error here.
        case .runStarted(let run):
            activeRunID = run.id
            runSummaries[run.id] = run
            if let prompt = transcript.last, prompt.role == .user,
                messageRunIDs[prompt.id] == nil
            {
                messageRunIDs[prompt.id] = run.id
            }
        case .runFinished(let run):
            publishAllStagedTools()
            settleStreamingPresentation(for: run.id)
            runSummaries[run.id] = run
            if activeRunID == run.id { activeRunID = nil }
        case .turnStarted:
            activeReasoningMessageID = nil
        case .turnFinished:
            activeReasoningMessageID = nil
            activeTurnMessageID = nil
        case .messageStarted(let started):
            activeReasoningMessageID = nil
            activeTurnMessageID = started.id
            if let activeRunID { messageRunIDs[started.id] = activeRunID }
            if let index = messages.firstIndex(where: { $0.id == started.id }) {
                messages[index].isStreaming = true
            } else {
                messages.append(
                    ChatMessage(
                        id: started.id, role: .assistant, text: "", isStreaming: true,
                        // The run's clock, not the UI's. See `AgentEvent.messageStarted`.
                        createdAt: started.createdAt
                    ))
            }
        case .messageDelta(let id, let text):
            if let activeRunID, messageRunIDs[id] != activeRunID {
                messageRunIDs[id] = activeRunID
            }
            applyMessageDelta(text, to: id)
        case .reasoningDelta(let id, let text):
            if activeReasoningMessageID != id { activeReasoningMessageID = id }
            if let activeRunID, messageRunIDs[id] != activeRunID {
                messageRunIDs[id] = activeRunID
            }
            applyReasoningDelta(text, to: id)
        // A queued turn has entered the model's context, so now it is part of
        // the conversation — in both lists, at the position the run put it, and
        // no longer in the queue the composer is drawing.
        case .steeringDelivered(let message):
            activeContextSnapshot = message.contextSnapshot
            if let activeRunID { messageRunIDs[message.id] = activeRunID }
            let pending = pendingSteering.first(where: { $0.id == message.id })
            let visibleText = pending?.draft ?? ContextChip.visiblePrompt(in: message.text)
            let contextChips =
                pending?.attachments.map {
                    ContextChipReference(
                        id: $0.id, kind: $0.kind, label: $0.label,
                        attachment: $0.contextAttachment
                    )
                }
                ?? ContextChip.visibleReferences(
                    in: message.text, images: message.images,
                    contextAttachments: message.contextAttachments
                )
            pendingSteering.removeAll { $0.id == message.id }
            messages.append(
                ChatMessage(
                    id: message.id, role: .user, text: visibleText,
                    contextChips: contextChips, images: message.images,
                    createdAt: message.createdAt
                ))
            transcript.append(message)
            contextEstimateTracker.upsert(message)
            publishContextEstimateImmediately()
        case .messageFinished(let message):
            if let activeRunID { messageRunIDs[message.id] = activeRunID }
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].text = message.text
                messages[index].reasoning = message.reasoning
                messages[index].isStreaming = false
            } else {
                messages.append(
                    ChatMessage(
                        id: message.id, role: .assistant, text: message.text,
                        reasoning: message.reasoning, isStreaming: false,
                        createdAt: message.createdAt
                    ))
            }
            // Whole message, not just its text: the tool calls and the opaque
            // provider items are what the next turn has to replay.
            if let index = transcript.firstIndex(where: { $0.id == message.id }) {
                transcript[index] = message
            } else {
                transcript.append(message)
            }
            contextEstimateTracker.upsert(message)
            publishContextEstimateImmediately()
            publishStagedTools(
                for: message.id,
                force: message.toolCalls.isEmpty
            )
            updatedAt = .now
        case .toolProposed(let invocation, let descriptor):
            stageTool(invocation, descriptor: descriptor)
        case .toolStarted(let invocation): setToolState(invocation.id, .running)
        // The card only, and the card's state is left alone: this is a call
        // still running, showing its work. Nothing here reaches `transcript` —
        // the model is owed one result per call, and it gets that from
        // `toolFinished`.
        case .toolProgress(let invocation, let partial):
            updateToolCard(invocation.id) { $0.result = partial }
        case .toolFinished(let invocation, let result):
            updateToolCard(invocation.id) { card in
                card.result = result
                // A denied call did not fail — someone said no. The denial is
                // an error to the *model*, which is what makes the turn
                // replayable, but the card kept being relabelled `Failed` the
                // instant it was refused, so `denied` never reached the screen.
                if result.isApprovalPolicyDenied {
                    card.state = .denied
                } else if card.state != .denied {
                    if result.isInterrupted {
                        card.state = .interrupted
                    } else {
                        card.state = result.isError ? .failed : .completed
                    }
                }
            }
            // A card, but not a turn. A provider-native search happened inside
            // the assistant's own turn and was never a tool call here, so
            // adding it to the model-facing transcript would replay a tool
            // result the provider has no matching call for — which it rejects
            // on the *next* request. See `AgentToolResult.isProviderNative`.
            guard !result.isProviderNative else { break }
            let message = AgentTranscriptMessage(
                id: AgentTranscriptMessage.toolResultID(runID: invocation.runID, callID: result.callID),
                role: .tool, text: result.content, toolCallID: result.callID,
                toolName: invocation.call.name, isError: result.isError, modelText: result.modelContent
            )
            transcript.append(message)
            contextEstimateTracker.upsert(message)
            publishContextEstimateImmediately()
        // The card only. The queue belongs to `requestApproval`, which is the
        // path that also holds the continuation — see its comment.
        case .approvalRequested(let request):
            // The direct user reply can beat this queued channel event to the UI.
            // A late notification must not erase a denial already shown on the card.
            updateToolCard(request.invocation.id) { card in
                if !card.state.isTerminal { card.state = .waitingForApproval }
            }
        case .reviewStarted(let request):
            reviewing.insert(request.invocation.id)
            setToolState(request.invocation.id, .reviewing)
        case .reviewFinished(let request, let decision):
            reviewing.remove(request.invocation.id)
            updateToolCard(request.invocation.id) { $0.review = decision }
        case .reviewFailed(let request, _, _):
            reviewing.remove(request.invocation.id)
            setToolState(request.invocation.id, .failed)
        // Also card-only. `request(_:)` enqueues, for the same reason.
        case .userInputRequested:
            break
        case .usageUpdated(let reported):
            usage = reported
            contextEstimateTracker.setMeasured(reported)
            if isStreaming {
                scheduleContextEstimatePublish()
            } else {
                publishContextEstimateImmediately()
            }
        case .planPresented(let plan):
            plans.append(AgentPlanCard(plan: plan))
        case .tasksUpdated(let updated):
            tasks = updated
        case .failed(let reason):
            messages.append(ChatMessage(role: .assistant, text: reason))
        }
    }

    private func stageTool(
        _ invocation: AgentToolInvocation,
        descriptor: AgentToolDescriptor
    ) {
        // A direct interaction may have staged this call before its queued event.
        // Refresh metadata without losing its state or creating a duplicate row.
        if updateToolCard(
            invocation.id,
            { card in
                card.invocation = invocation
                card.descriptor = descriptor
            })
        {
            return
        }
        let card = AgentToolCard(invocation: invocation, descriptor: descriptor)
        guard let sourceMessageID = invocation.sourceMessageID else {
            toolCards.append(card)
            return
        }
        if stagedToolCards[invocation.id] == nil {
            stagedToolOrder.append(invocation.id)
        }
        stagedToolCards[invocation.id] = card

        guard let source = transcript.first(where: { $0.id == sourceMessageID }) else {
            // Provider-native activities arrive while the assistant message is
            // still streaming. Keep all of them staged until messageFinished
            // seals that turn, then publish the complete set in one mutation.
            if activeTurnMessageID == sourceMessageID { return }
            // Restored/legacy/manual event streams may not carry the source
            // assistant message. There is no authoritative call set to await,
            // so prefer a visible stable batch over hiding the card forever.
            publishStagedTools(for: sourceMessageID, force: true)
            return
        }
        publishStagedTools(
            for: sourceMessageID,
            force: source.toolCalls.isEmpty
        )
    }

    /// Publishes every card for a provider response in one observable mutation.
    /// `force` is used for provider-native activities, whose synthetic calls do
    /// not occur in the assistant message's model-facing `toolCalls` array.
    private func publishStagedTools(for sourceMessageID: UUID, force: Bool = false) {
        let stagedIDs = stagedToolOrder.filter {
            stagedToolCards[$0]?.invocation.sourceMessageID == sourceMessageID
        }
        guard !stagedIDs.isEmpty else { return }

        if !force {
            guard let source = transcript.first(where: { $0.id == sourceMessageID }),
                !source.toolCalls.isEmpty
            else { return }
            let stagedCallIDs = Set(
                stagedIDs.compactMap {
                    stagedToolCards[$0]?.invocation.call.id
                })
            guard source.toolCalls.allSatisfy({ stagedCallIDs.contains($0.id) }) else {
                return
            }
        }

        let cards = stagedIDs.compactMap { stagedToolCards.removeValue(forKey: $0) }
        let published = Set(stagedIDs)
        stagedToolOrder.removeAll { published.contains($0) }
        toolCards.append(contentsOf: cards)
    }

    private func publishAllStagedTools() {
        guard !stagedToolOrder.isEmpty else { return }
        let cards = stagedToolOrder.compactMap { stagedToolCards.removeValue(forKey: $0) }
        stagedToolOrder.removeAll(keepingCapacity: true)
        toolCards.append(contentsOf: cards)
    }

    @discardableResult
    private func updateToolCard(
        _ id: UUID,
        _ update: (inout AgentToolCard) -> Void
    ) -> Bool {
        if var staged = stagedToolCards[id] {
            update(&staged)
            stagedToolCards[id] = staged
            return true
        }
        guard let index = toolCards.firstIndex(where: { $0.id == id }) else {
            return false
        }
        update(&toolCards[index])
        return true
    }

    private func setToolState(_ id: UUID, _ state: AgentToolCard.State) {
        updateToolCard(id) { $0.state = state }
    }

    /// Adds a final speech-recognition result without disturbing text the user
    /// already wrote. The callback keeps the standalone composer and the
    /// sidebar's "promote draft to conversation" path on the same behavior.
    @discardableResult
    public func applyTranscription(
        _ transcript: String,
        sendAfterTranscription: Bool,
        send: () -> Void
    ) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        if composer.draft.isEmpty {
            composer.draft = cleaned
        } else if composer.draft.last?.isWhitespace == true {
            composer.draft += cleaned
        } else {
            composer.draft += " " + cleaned
        }

        if sendAfterTranscription { send() }
        return true
    }
}

extension ConversationModel: AgentUserInteractionHandling {}

/// Lets a run ask its conversation a question without keeping it alive.
///
/// `AgentRuntime` holds its interaction handler for the whole run and the
/// conversation holds the runtime, so handing the conversation over directly
/// closed a reference cycle. A conversation that has been deallocated cannot
/// answer, and an unanswerable prompt is a cancelled one.
public final class WeakAgentUserInteraction {
    private weak var conversation: ConversationModel?

    public init(_ conversation: ConversationModel) {
        self.conversation = conversation
    }

    public func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        guard let conversation else { return .cancelled }
        return await conversation.request(request)
    }

    /// The SSH checkpoints, in the shape the tools take them — see
    /// `AgentSSHInteraction`. Weak for the same reason `request` is.
    public var sshInteraction: AgentSSHInteraction {
        AgentSSHInteraction(
            authenticate: { [weak conversation] request in
                guard let conversation else { return .cancelled }
                return await conversation.requestSSHAuthentication(request)
            },
            confirmHostKey: { [weak conversation] request in
                guard let conversation else { return .deny }
                return await conversation.requestSSHHostKeyConfirmation(request)
            }
        )
    }
}

extension WeakAgentUserInteraction: AgentUserInteractionHandling {}

// MARK: - Demo data

extension ConversationModel {
    public static func demo(language: AppLanguage = .english) -> ConversationModel {
        func text(_ en: String, _ zhHans: String, _ zhHant: String) -> String {
            switch language {
            case .simplifiedChinese: zhHans
            case .traditionalChinese: zhHant
            case .system, .english: en
            }
        }
        let now = Date(timeIntervalSinceReferenceDate: 809_020_800)
        let user = ChatMessage(
            role: .user,
            text: text(
                "Find the cause of the 502 responses. Inspect only—do not change configuration.",
                "查明 502 响应的原因。仅检查，不要更改配置。",
                "找出 502 回應的原因。僅進行檢查，不要變更設定。"
            ),
            createdAt: now.addingTimeInterval(-18)
        )
        let answer = ChatMessage(
            role: .assistant,
            text: text(
                "The upstream service is not listening on `127.0.0.1:8080`. Nginx itself is healthy, and no configuration was changed. Start the upstream service, then verify `/health` before considering a reload.",
                "上游服务没有监听 `127.0.0.1:8080`。Nginx 本身运行正常，且没有更改任何配置。请先启动上游服务并验证 `/health`，再考虑重新加载。",
                "上游服務未監聽 `127.0.0.1:8080`。Nginx 本身運作正常，且未變更任何設定。請先啟動上游服務並驗證 `/health`，再考慮重新載入。"
            ),
            createdAt: now
        )
        let runID = UUID()
        let descriptor = AgentToolDescriptor(
            name: "ssh_exec",
            summary: text("Run a command on a remote host.", "在远程主机上运行命令。", "在遠端主機上執行指令。"),
            inputSchema: .object([:]), target: .host, approvalPolicy: .approve,
            concurrency: .parallel,
            presentation: AgentToolDescriptor.Presentation(
                symbol: "apple.terminal", activity: .argument(key: "command", fallback: "command"),
                actionKind: .run
            )
        )
        let commands = [
            "systemctl status nginx --no-pager",
            "tail -n 80 /var/log/nginx/error.log",
        ]
        let cards = commands.enumerated().map { index, command in
            AgentToolCard(
                invocation: AgentToolInvocation(
                    runID: runID,
                    call: AgentToolCall(
                        id: "demo-\(index)", name: "ssh_exec",
                        arguments: .object(["command": .string(command)])
                    ),
                    targetHostID: nil,
                    createdAt: now.addingTimeInterval(Double(index - 12))
                ),
                descriptor: descriptor,
                state: .completed
            )
        }
        let conversation = ConversationModel(
            messages: [user, answer],
            runs: [
                AgentRunSummary(
                    id: runID, state: .completed,
                    startedAt: now.addingTimeInterval(-15),
                    finishedAt: now.addingTimeInterval(-3)
                )
            ]
        )
        conversation.customTitle = text("Diagnose 502 responses", "诊断 502 响应", "診斷 502 回應")
        conversation.messages = [
            user, answer,
        ]
        conversation.toolCards = cards
        return conversation
    }
}

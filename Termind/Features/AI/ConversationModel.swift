import Foundation

/// A command the model proposed. It is *never* executed on the model's say-so —
/// `risk` is computed locally by `CommandRiskClassifier` and the user always
/// clicks.
nonisolated struct SuggestedCommand: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var command: String
    var explanation: String = ""

    var risk: RiskAssessment {
        CommandRiskClassifier.assess(command)
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
nonisolated struct ContextChip: Identifiable, Hashable, Sendable {
    /// `CaseIterable` so `blockName` can be read backwards: a composed message
    /// carries these tags into the transcript, and rendering one as an
    /// attachment row means recognising the tag it came from.
    nonisolated enum Kind: Hashable, Sendable, CaseIterable {
        case host, directory, output, selection, file, image, pastedText

        var symbol: String {
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
        var blockName: String {
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

    var id: UUID = UUID()
    var kind: Kind
    var label: String
    var content: String = ""
    var image: AgentImageAttachment? = nil

    /// Derived, not declared. A hand-passed count is a number that was true
    /// once, and the estimate exists to warn about payload size.
    ///
    /// Shares `AgentContextEstimator`'s divisor rather than repeating `/ 4`, so
    /// a chip and the context gauge can never quote different sizes for the
    /// same attachment.
    var approximateTokens: Int {
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
    static func visiblePrompt(in composedText: String) -> String {
        let boundaries = Kind.allCases.compactMap { kind in
            composedText.range(of: "\n\n<\(kind.blockName) label=\"")?.lowerBound
        }
        guard let boundary = boundaries.min() else { return composedText }
        return String(composedText[..<boundary])
    }

    /// Rebuilds lightweight bubble chips from the model-facing markup without
    /// retaining or rendering the payload between the tags.
    static func visibleReferences(
        in composedText: String, images: [AgentImageAttachment] = []
    ) -> [ContextChipReference] {
        let boundary = Kind.allCases.compactMap { kind in
            composedText.range(of: "\n\n<\(kind.blockName) label=\"")?.lowerBound
        }.min()

        var matches: [(String.Index, ContextChipReference)] = []
        if let boundary {
            let suffix = composedText[boundary...]
            for kind in Kind.allCases where kind != .image {
                let prefix = "<\(kind.blockName) label=\""
                var cursor = suffix.startIndex
                while let opening = suffix.range(of: prefix, range: cursor..<suffix.endIndex) {
                    let labelStart = opening.upperBound
                    guard let labelEnd = suffix.range(
                        of: "\">", range: labelStart..<suffix.endIndex
                    ) else { break }
                    matches.append((
                        opening.lowerBound,
                        ContextChipReference(
                            kind: kind, label: String(suffix[labelStart..<labelEnd.lowerBound])
                        )
                    ))
                    cursor = labelEnd.upperBound
                }
            }
        }

        let textReferences = matches.sorted { $0.0 < $1.0 }.map(\.1)
        let imageReferences = images.map {
            ContextChipReference(id: $0.id, kind: .image, label: $0.label)
        }
        return textReferences + imageReferences
    }
}

/// The non-payload part of a Context Chip kept by the display projection.
///
/// A sent PDF can contain 200,000 characters; the bubble needs only these few
/// bytes to show what accompanied the prompt.
nonisolated struct ContextChipReference: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var kind: ContextChip.Kind
    var label: String
}

nonisolated struct PendingContextAttachment: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var label: String
}

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    nonisolated enum Role: Hashable, Sendable {
        case user, assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
    var reasoning: [AgentReasoningBlock] = []
    var contextChips: [ContextChipReference] = []
    var images: [AgentImageAttachment] = []
    var commands: [SuggestedCommand] = []
    /// True while tokens are still arriving, so the view can show a caret.
    var isStreaming: Bool = false
    /// Orders this message against the tool cards, which are a separate list.
    /// Restored conversations carry their stored time so history does not
    /// re-sort itself behind every card the moment a window opens.
    var createdAt: Date = .now
}

nonisolated struct AgentToolCard: Identifiable, Hashable, Sendable {
    nonisolated enum State: String, Hashable, Sendable {
        case proposed, waitingForApproval, waitingForUser, reviewing, running, completed, denied, failed
        case interrupted

        /// The transcript used to show `rawValue.capitalized`, which put the
        /// case name itself on screen — `WaitingForApproval`. The raw value is
        /// a storage key; this is the label.
        var displayName: String {
            switch self {
            case .proposed: String(localized: "Proposed")
            case .waitingForApproval: String(localized: "Waiting for approval")
            case .waitingForUser: String(localized: "Waiting for authentication")
            case .reviewing: String(localized: "Reviewing")
            case .running: String(localized: "Running")
            case .completed: String(localized: "Completed")
            case .denied: String(localized: "Denied")
            case .failed: String(localized: "Failed")
            case .interrupted: String(localized: "Interrupted")
            }
        }

        /// Whether a card in this state opens itself.
        ///
        /// Anything still in flight, or anything that went wrong, is what the
        /// reader is actually looking for. A call that simply worked is noise
        /// once it has worked.
        var revealsDetailByDefault: Bool {
            switch self {
            case .waitingForApproval, .waitingForUser, .reviewing, .running, .denied, .failed: true
            case .interrupted: false
            case .proposed, .completed: false
            }
        }

        var isTerminal: Bool {
            switch self {
            case .completed, .denied, .failed, .interrupted: true
            case .proposed, .waitingForApproval, .waitingForUser, .reviewing, .running: false
            }
        }
    }

    var id: UUID { invocation.id }
    var invocation: AgentToolInvocation
    var descriptor: AgentToolDescriptor
    var state: State = .proposed
    var result: AgentToolResult?
    var review: SecurityReviewDecision?
}

/// One message the user sent while a run was in flight, waiting on the next
/// model boundary.
///
/// `draft` and `attachments` are kept beside the composed message because the
/// queue is a promise that can be broken — a stopped run hands these back to the
/// composer, and handing back `message.text` would return the user their own
/// attachment blocks to edit.
nonisolated struct PendingSteeringMessage: Identifiable, Hashable, Sendable {
    /// The message's own id, so delivery is matched on identity rather than on
    /// comparing text with text.
    var id: AgentTranscriptMessage.ID { message.id }
    var draft: String
    var attachments: [ContextChip] = []
    var message: AgentTranscriptMessage
}

/// One row of a conversation, whichever of the two lists it came from.
nonisolated enum TimelineItem: Identifiable, Hashable, Sendable {
    case message(ChatMessage)
    case tool(AgentToolCard)
    case work(AgentWorkGroup)
    case plan(AgentPlanCard)
    case compaction(AgentCompactionMark)
    case compactionActivity(AgentCompactionActivity)

    var id: UUID {
        switch self {
        case .message(let message): message.id
        case .tool(let card): card.id
        case .work(let group): group.id
        case .plan(let card): card.id
        case .compaction(let mark): mark.id
        case .compactionActivity(let activity): activity.id
        }
    }

    /// The run's clock, not the UI's — the same stamp `timeline` merges the two
    /// existing lists on. See `AgentEvent.messageStarted`.
    var orderedAt: Date {
        switch self {
        case .message(let message): message.createdAt
        case .tool(let card): card.invocation.createdAt
        case .work(let group): group.orderedAt
        case .plan(let card): card.createdAt
        case .compaction(let mark): mark.createdAt
        case .compactionActivity(let activity): activity.createdAt
        }
    }

    /// Breaks a tie at the same instant. A compaction mark is anchored to the
    /// last message it summarized, so it belongs *after* that message rather
    /// than in a position `sorted` is free to pick either way — Swift's sort is
    /// not stable, so equal timestamps otherwise swap between redraws.
    var sortRank: Int {
        switch self {
        case .work: -1
        case .compaction, .compactionActivity: 1
        default: 0
        }
    }

    /// What the transcript scrolls to, and what a change to it must be visible
    /// as: streaming text grows a message without changing any count.
    var revision: Int {
        var hasher = Hasher()
        hasher.combine(id)
        switch self {
        case .message(let message):
            hasher.combine(message.text.count)
            hasher.combine(message.images.count)
            hasher.combine(message.isStreaming)
        case .tool(let card):
            hasher.combine(card.state)
            hasher.combine(card.result?.content.count ?? 0)
        case .work(let group):
            hasher.combine(group)
        case .plan(let card):
            // The outcome, so answering a plan re-triggers the scroll the same
            // way a tool card finishing does.
            hasher.combine(card.outcome)
        case .compaction(let mark):
            hasher.combine(mark.keptTokens)
        case .compactionActivity(let activity):
            hasher.combine(activity.state)
        }
        return hasher.finalize()
    }
}

nonisolated enum AgentWorkItem: Identifiable, Hashable, Sendable {
    case reasoning(AgentReasoningBlock)
    case message(ChatMessage)
    case tool(AgentToolCard)
    /// Two or more contiguous tool calls, regardless of their current result.
    /// The view shows activity until every member is terminal, then summarizes.
    case tools([AgentToolCard])

    var id: UUID {
        switch self {
        case .reasoning(let block): block.id
        case .message(let message): message.id
        case .tool(let card): card.id
        case .tools(let cards):
            cards.first?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        }
    }

    var orderedAt: Date {
        switch self {
        case .reasoning(let block): block.createdAt
        case .message(let message): message.createdAt
        case .tool(let card): card.invocation.createdAt
        case .tools(let cards): cards.first?.invocation.createdAt ?? .distantPast
        }
    }
}

nonisolated struct AgentWorkGroup: Identifiable, Hashable, Sendable {
    var id: UUID { run.id }
    var run: AgentRunSummary
    var items: [AgentWorkItem]
    var orderedAt: Date
    var anchorMessageID: UUID?
    var appearsAfterAnswer: Bool
    /// The provider summary currently receiving deltas. The view scans this
    /// text instead of showing a second generic Working indicator outside.
    var activeReasoningBlockID: AgentReasoningBlock.ID?
}

nonisolated enum AgentWorkPresentation {
    static func isExpandedByDefault(
        for state: AgentRunState, appearsAfterAnswer: Bool = false
    ) -> Bool {
        state != .completed || appearsAfterAnswer
    }

    /// A compact, stable duration for the work disclosure. Seconds are floored
    /// so a completed run never appears to gain time after its finish event.
    static func duration(from startedAt: Date, to finishedAt: Date) -> String {
        let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return remainingSeconds > 0
                ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
        }
        return "\(remainingSeconds)s"
    }

    static func title(
        for state: AgentRunState, from startedAt: Date, to finishedAt: Date
    ) -> String {
        let elapsed = duration(from: startedAt, to: finishedAt)
        switch state {
        case .idle, .running, .waitingForUser, .waitingForApproval, .reviewing:
            return "Working for \(elapsed)"
        case .cancelled:
            return "You stopped after \(elapsed)"
        case .completed, .failed, .interrupted:
            return "Worked for \(elapsed)"
        }
    }
}

nonisolated struct AgentCompactionActivity: Identifiable, Hashable, Sendable {
    nonisolated enum State: Hashable, Sendable {
        case running
        case failed(String)
    }

    var id: UUID = UUID()
    var state: State
    var createdAt: Date = .now
}

/// The line in the transcript where history stopped being sent.
///
/// The messages above it are *not* deleted. Compaction shapes what is sent, and
/// the codebase's rule is that transforms never shape what is kept — see
/// `AgentContextPipeline`. So the conversation stays scrollable and this says
/// where the model's memory of it now begins.
nonisolated struct AgentCompactionMark: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var summarizedTokens: Int
    var keptTokens: Int
    var createdAt: Date = .now
}

/// A presented plan and what became of it.
///
/// A row of the transcript rather than a panel above the composer: it is part of
/// what happened, in the order it happened, and it stays readable after it has
/// been answered. Nothing is suspended waiting on it — see `AgentPlanModeHook`.
nonisolated struct AgentPlanCard: Identifiable, Hashable, Sendable {
    var id: UUID { plan.id }
    var plan: AgentPlan
    var outcome: AgentPlan.Outcome = .pending
    /// Ordered against messages and tool cards by the same clock they use.
    var createdAt: Date { plan.createdAt }
}

/// The approval posture selected for one conversation.
///
/// This turn-level state does not yet alter command or MCP execution. Keeping
/// it separate from those existing approval gates prevents a UI choice from
/// silently weakening either one before the agent execution pipeline exists.
nonisolated enum ChatPermissionMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case askForApproval, approveForMe, fullAccess

    nonisolated var id: String { rawValue }

    var displayName: String {
        switch self {
        case .askForApproval: String(localized: "Ask for approval")
        case .approveForMe: String(localized: "Approve for me")
        case .fullAccess: String(localized: "Full access")
        }
    }

    var symbol: String {
        switch self {
        case .askForApproval: "hand.raised"
        case .approveForMe: "checkmark.shield"
        case .fullAccess: "lock.open"
        }
    }
}

/// One AI conversation, wherever it is being shown.
///
/// It deliberately knows nothing about a session. Where the conversation is
/// *about* a host and a directory, that comes from the surface showing it —
/// `WindowSidebarState.sessionContext` — because a conversation that owned its
/// own session context carried it into the Assistant tab, which has no session
/// to describe.
@Observable
final class ConversationModel: Identifiable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var customTitle: String?
    var isPinned = false
    var archivedAt: Date?
    var messages: [ChatMessage] = []
    /// What the user attached by hand, each carrying its own payload. Consumed
    /// by the next user turn: an attachment belongs to one message, and once
    /// that message is sent the content is in the transcript already.
    var attachments: [ContextChip] = []
    var pendingAttachments: [PendingContextAttachment] = []
    var attachmentImportError: String?
    var draft: String = ""
    private(set) var isStreaming: Bool = false
    /// What the transcript shows. Derived — see `refreshRunState`.
    private(set) var runState: AgentRunState = .idle
    /// The last state the *run* reported, before anything outstanding in the UI
    /// is taken into account.
    private var runtimeState: AgentRunState = .idle
    var toolCards: [AgentToolCard] = []
    private(set) var runSummaries: [UUID: AgentRunSummary] = [:]
    private(set) var messageRunIDs: [UUID: UUID] = [:]
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
    private(set) var pendingApprovals: [AgentApprovalRequest] = []
    private(set) var pendingUserInputs: [AgentUserInputRequest] = []
    private(set) var pendingSSHAuthentications: [AgentSSHAuthenticationRequest] = []
    /// What the user typed at a busy agent, oldest first, none of it delivered
    /// yet. See `submitSteeringDraft`.
    private(set) var pendingSteering: [PendingSteeringMessage] = []
    /// Reviews in flight. Counted rather than flagged: they run concurrently,
    /// so the last one to finish must not be able to announce that none are.
    private var reviewing: Set<UUID> = []

    var pendingApproval: AgentApprovalRequest? { pendingApprovals.first }
    var pendingUserInput: AgentUserInputRequest? { pendingUserInputs.first }
    var pendingSSHAuthentication: AgentSSHAuthenticationRequest? {
        pendingSSHAuthentications.first
    }
    enum PendingUserInteraction {
        case questions(AgentUserInputRequest)
        case sshAuthentication(AgentSSHAuthenticationRequest)
    }
    var pendingUserInteraction: PendingUserInteraction? {
        switch (pendingUserInput, pendingSSHAuthentication) {
        case (let input?, let authentication?):
            return input.createdAt <= authentication.createdAt
                ? .questions(input) : .sshAuthentication(authentication)
        case (let input?, nil): return .questions(input)
        case (nil, let authentication?): return .sshAuthentication(authentication)
        case (nil, nil): return nil
        }
    }
    /// What has been filled in so far, keyed by question. One request can now
    /// carry several questions, so the drafts are per question rather than one
    /// pair of fields shared by whichever one happened to be on screen.
    private(set) var userInputDrafts: [String: AgentUserInputDraft] = [:]
    private(set) var currentUserInputQuestionIndex = 0
    private(set) var skippedUserInputQuestionIDs: Set<String> = []
    /// Kept out of `userInputDrafts` on purpose: a secret does not belong in
    /// the same dictionary as text that is echoed back to the model.
    var secretInputDraft = ""
    /// The model-facing history, which is not what `messages` holds.
    ///
    /// `messages` is a display projection: it has no tool calls and no tool
    /// results, because those are drawn as cards. Replaying it as the next run's
    /// prior context loses every tool the agent already ran, and turns a
    /// tool-only assistant turn into an empty message — which Anthropic and
    /// Google both reject. So the authoritative transcript is kept beside it and
    /// rebuilt from the same events.
    private(set) var transcript: [AgentTranscriptMessage] = []
    private var runtime: AgentRuntime?
    private var eventTask: Task<Void, Never>?
    private var approvalWaiters: [UUID: CheckedContinuation<AgentApprovalDecision, Never>] = [:]
    private var inputWaiters: [UUID: CheckedContinuation<AgentUserInputResponse, Never>] = [:]
    private var userInputTimeoutTask: Task<Void, Never>?
    private var sshAuthenticationWaiters: [UUID: CheckedContinuation<AgentSSHAuthenticationResponse, Never>] = [:]

    /// Whether the agent may only look.
    ///
    /// Per conversation and deliberately not remembered app-wide the way
    /// `lastSelectedPermissionMode` is. Permission mode is a standing preference
    /// about how much you trust the agent; this is a posture for one task, and a
    /// mode silently inherited by tomorrow's conversation is a mode nobody asked
    /// for.
    var isPlanning = false

    /// Plans presented in this conversation, oldest first.
    private(set) var plans: [AgentPlanCard] = []

    /// Where history stopped being sent, oldest first. Display only — the
    /// authoritative record of a compaction is the `isCompaction` turn in
    /// `transcript`, which is what survives a relaunch.
    private(set) var compactions: [AgentCompactionMark] = []

    /// Ephemeral UI state. Successful compactions become boundary marks; a
    /// failed attempt stays readable for this process without entering the
    /// model transcript or persistence schema.
    private(set) var compactionActivity: AgentCompactionActivity?

    /// True while a compaction is in flight, so the composer can say so and not
    /// start a second one.
    private(set) var isCompacting = false

    /// The current task list, whole. Replaced rather than patched — see
    /// `AgentTask`.
    private(set) var tasks: [AgentTask] = []

    var completedTaskCount: Int { tasks.filter { $0.status == .completed }.count }

    /// How many characters of tool schema the last run sent.
    ///
    /// Recorded when a run starts rather than derived on demand: the registry is
    /// assembled per run from Vault hosts, MCP servers and the search plan, and
    /// a composer redrawing on every keystroke must not rebuild it. Zero until
    /// the first run, which is honest — nothing has been sent yet.
    private(set) var toolSchemaCharacters = 0

    func noteToolSchemas(_ descriptors: [AgentToolDescriptor]) {
        toolSchemaCharacters = descriptors.reduce(0) { total, descriptor in
            total + descriptor.name.count + descriptor.summary.count
                + descriptor.inputSchema.encodedString.count
        }
    }

    /// The conversation as a gauge sees it, provider-measured where possible.
    var contextEstimate: AgentContextEstimate {
        AgentContextEstimator.estimate(
            systemPrompt: AgentSystemPrompt.default,
            toolSchemaCharacters: toolSchemaCharacters,
            transcript: transcript,
            attachedCharacters: attachments.reduce(0) {
                $0 + ($1.image == nil ? $1.content.count : $1.approximateTokens * 4)
            },
            measured: usage
        )
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
    private(set) var usage: AgentTokenUsage?

    /// Per-conversation reasoning state, normalized against the resolved model
    /// by the composer before a request is made.
    var reasoningEffort: ReasoningEffort = .medium

    /// An explicit choice for this conversation. `nil` follows the app-wide
    /// last selection through `AIConfigurationModel.resolve(conversation:)`, the same shape
    /// used by `model` below.
    var permissionMode: ChatPermissionMode?

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
    var model: AIModelRef?

    /// The generated summary, once there has been something to summarize.
    /// `nil` — not "", which is what an unset stored row decodes to — is what
    /// makes `derivedTitle` fall back rather than show an empty row.
    var title: String?

    /// Fired when a run reaches a terminal state, so `AppModel` can title the
    /// conversation without the conversation knowing what a title costs.
    var runDidFinish: (() -> Void)?

    init(
        id: UUID = UUID(), messages: [ChatMessage] = [],
        transcript: [AgentTranscriptMessage] = [],
        runState: AgentRunState = .idle,
        messageRunIDs: [UUID: UUID] = [:],
        runs: [AgentRunSummary] = [],
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.transcript = transcript
        self.messageRunIDs = messageRunIDs
        runSummaries = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        self.runState = runState
        runtimeState = runState
    }

    var estimatedContextTokens: Int {
        attachments.reduce(0) { $0 + $1.approximateTokens }
    }

    /// The generated summary if there is one, and the opening line until then.
    ///
    /// The fallback is not a placeholder to be replaced on refresh — a title is
    /// generated once, so this is what a conversation shows when the summary
    /// never ran: no model configured, the request failed, or the first reply
    /// has not arrived yet.
    var derivedTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if let title, !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user }) else {
            return String(localized: "New Chat")
        }
        let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    var isEmpty: Bool { timeline.isEmpty }
    var isArchived: Bool { archivedAt != nil }

    var metadata: StoredAgentConversationMetadata {
        StoredAgentConversationMetadata(
            customTitle: customTitle ?? "", isPinned: isPinned,
            archivedAt: archivedAt, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    func canEditUserMessage(_ id: UUID) -> Bool {
        guard !isStreaming, !isCompacting, !isArchived else { return false }
        return transcript.contains { $0.id == id && $0.role == .user && !$0.isCompaction }
    }

    func canForkAssistantMessage(_ id: UUID) -> Bool {
        guard !isStreaming, !isCompacting, !isArchived else { return false }
        return transcript.contains { $0.id == id && $0.role == .assistant }
    }

    func editedUserMessage(_ id: UUID, authoredText: String) -> AgentTranscriptMessage? {
        guard canEditUserMessage(id),
            let target = transcript.firstIndex(where: { $0.id == id })
        else { return nil }
        let original = transcript[target]
        let visible = original.authoredText ?? ContextChip.visiblePrompt(in: original.text)
        let suffix = original.text.hasPrefix(visible)
            ? String(original.text.dropFirst(visible.count)) : ""
        return AgentTranscriptMessage(
            role: .user, text: authoredText + suffix, authoredText: authoredText,
            images: original.images, createdAt: .now
        )
    }

    func editUserMessage(
        _ id: UUID, replacement: AgentTranscriptMessage
    ) -> ComposedUserTurn? {
        guard canEditUserMessage(id),
            let target = transcript.firstIndex(where: { $0.id == id })
        else { return nil }
        let original = transcript[target]
        let removedMessageIDs = Set(transcript[target...].map(\.id))
        let removedRunIDs = Set(removedMessageIDs.compactMap { messageRunIDs[$0] })
        transcript.replaceSubrange(target..., with: [replacement])

        if let visibleIndex = messages.firstIndex(where: { $0.id == id }) {
            messages.replaceSubrange(visibleIndex..., with: [ChatMessage(
                id: replacement.id, role: .user,
                text: replacement.authoredText ?? ContextChip.visiblePrompt(in: replacement.text),
                contextChips: ContextChip.visibleReferences(
                    in: replacement.text, images: replacement.images
                ), images: replacement.images, createdAt: replacement.createdAt
            )])
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
        runtimeState = .idle
        refreshRunState()
        updatedAt = replacement.createdAt
        if !transcript[..<target].contains(where: { $0.role == .user && !$0.isCompaction }) {
            title = nil
        }
        return ComposedUserTurn(
            id: replacement.id, text: replacement.text,
            authoredText: replacement.authoredText ?? "", images: replacement.images
        )
    }

    func editUserMessage(_ id: UUID, authoredText: String) -> ComposedUserTurn? {
        guard let replacement = editedUserMessage(id, authoredText: authoredText) else {
            return nil
        }
        return editUserMessage(id, replacement: replacement)
    }

    func forked(
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
                        in: message.text, images: message.images
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
        let fork = ConversationModel(
            messages: visibleMessages, transcript: cloned, runState: .completed,
            messageRunIDs: clonedMessageRunIDs, runs: clonedRuns,
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
    nonisolated static func numberedForkTitle(base: String, index: Int) -> String {
        let suffix = " (\(index))"
        return String(base.prefix(max(0, 80 - suffix.count))) + suffix
    }

    /// One collapsible work group per run. Source-message ownership is the
    /// primary key; call ids and run-local order are compatibility fallbacks
    /// for rows written before `sourceMessageID` existed.
    var workGroups: [AgentWorkGroup] {
        let visibleByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        let cardsByRun = Dictionary(grouping: toolCards, by: { $0.invocation.runID })
        let toolProcessMessageIDs = Set(transcript.compactMap { message -> UUID? in
            message.role == .assistant && !message.toolCalls.isEmpty ? message.id : nil
        })
        var processRunIDs: [UUID: UUID] = [:]
        for message in transcript where message.role == .assistant && !message.toolCalls.isEmpty {
            if let runID = messageRunIDs[message.id] {
                processRunIDs[message.id] = runID
                continue
            }
            let callIDs = Set(message.toolCalls.map(\.id))
            if let card = toolCards.first(where: {
                $0.invocation.sourceMessageID == message.id
                    || callIDs.contains($0.invocation.call.id)
            }) {
                processRunIDs[message.id] = card.invocation.runID
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
            let visibleProcess = processMessages.filter { message in
                let livePlaceholder = message.isStreaming && message.text.isEmpty
                    && message.reasoning.isEmpty
                let toolProcess = toolProcessMessageIDs.contains(message.id)
                    && (!message.text.isEmpty
                        || (message.isStreaming && message.reasoning.isEmpty))
                return livePlaceholder || toolProcess
            }
            let reasoningItems = processMessages.flatMap { message -> [AgentWorkItem] in
                guard message.id == activeReasoningMessageID else { return [] }
                return message.reasoning.map(AgentWorkItem.reasoning)
            }
            let activeReasoningBlockID = processMessages.first(where: {
                $0.id == activeReasoningMessageID && $0.isStreaming && $0.text.isEmpty
            })?.reasoning.last?.id
            var items = reasoningItems + visibleProcess.map(AgentWorkItem.message)
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
            // A provider turn is the semantic boundary for a tool batch. Most
            // cards carry it directly as sourceMessageID. Rows restored from
            // older stores may not, so recover it from the assistant tool call
            // while treating duplicate call ids as ambiguous.
            var recoveredSourceByCallID: [String: UUID] = [:]
            var ambiguousCallIDs = Set<String>()
            for message in transcript
            where message.role == .assistant && processRunIDs[message.id] == runID
            {
                for call in message.toolCalls {
                    if let existing = recoveredSourceByCallID[call.id], existing != message.id {
                        recoveredSourceByCallID[call.id] = nil
                        ambiguousCallIDs.insert(call.id)
                    } else if !ambiguousCallIDs.contains(call.id) {
                        recoveredSourceByCallID[call.id] = message.id
                    }
                }
            }
            let sourceMessageIDs = Dictionary(uniqueKeysWithValues: cards.compactMap { card in
                let source = card.invocation.sourceMessageID
                    ?? recoveredSourceByCallID[card.invocation.call.id]
                return source.map { (card.id, $0) }
            })
            items = Self.groupAdjacentTools(
                in: items, sourceMessageIDs: sourceMessageIDs
            )
            let stored = runSummaries[runID]
            // A user stop is useful transcript state even when it interrupted a
            // direct response before any tool or process item was produced.
            guard !items.isEmpty || stored?.state == .cancelled else { return nil }

            // The work row follows the clock of the first thing it actually
            // presents. A stopped direct answer has no work item, so its stop
            // event is the row's place in the timeline.
            let orderedAt = items.first?.orderedAt
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
            let fallbackState: AgentRunState = cards.allSatisfy {
                $0.state == .completed
            } ? .completed : .interrupted
            let run = stored ?? AgentRunSummary(
                id: runID, state: fallbackState,
                startedAt: items.first?.orderedAt ?? orderedAt,
                finishedAt: items.last?.orderedAt
            )
            return AgentWorkGroup(
                run: run, items: items, orderedAt: orderedAt,
                anchorMessageID: anchorID, appearsAfterAnswer: answerAt != nil,
                activeReasoningBlockID: activeReasoningBlockID
            )
        }.sorted { $0.orderedAt < $1.orderedAt }
    }

    private static func groupAdjacentTools(
        in items: [AgentWorkItem], sourceMessageIDs: [AgentToolCard.ID: UUID]
    ) -> [AgentWorkItem] {
        var grouped: [AgentWorkItem] = []
        var adjacent: [AgentToolCard] = []
        var adjacentSourceMessageID: UUID?
        func flush() {
            guard !adjacent.isEmpty else { return }
            if adjacent.count == 1 {
                grouped.append(.tool(adjacent[0]))
            } else {
                grouped.append(.tools(adjacent))
            }
            adjacent.removeAll(keepingCapacity: true)
            adjacentSourceMessageID = nil
        }
        for item in items {
            if case .tool(let card) = item {
                if card.descriptor.presentation?.groupsWithAdjacentTools == false {
                    flush()
                    grouped.append(.tool(card))
                    continue
                }
                guard let sourceMessageID = sourceMessageIDs[card.id] else {
                    flush()
                    grouped.append(.tool(card))
                    continue
                }
                if let adjacentSourceMessageID,
                    adjacentSourceMessageID != sourceMessageID
                {
                    flush()
                }
                adjacentSourceMessageID = sourceMessageID
                adjacent.append(card)
            } else {
                flush()
                grouped.append(item)
            }
        }
        flush()
        return grouped
    }

    /// Messages and run-scoped work in the order the reader experienced them.
    var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        let groups = workGroups
        let groupedProcessIDs: Set<UUID> = Set(groups.flatMap { group -> [UUID] in
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
            guard message.role != .assistant || !message.text.isEmpty
                || (message.isStreaming && message.reasoning.isEmpty)
            else { continue }
            items.append(.message(message))
        }
        items += groups.filter { !emittedGroups.contains($0.id) }.map(TimelineItem.work)
        guard !plans.isEmpty || !compactions.isEmpty || compactionActivity != nil else {
            return items
        }
        // Merged by time rather than woven into the loop above. A plan ends its
        // run and a compaction happens between runs, so there are never many of
        // either, and two more cursors inside that loop would be two more things
        // to keep right for no gain.
        var extra = plans.map(TimelineItem.plan) + compactions.map(TimelineItem.compaction)
        if let compactionActivity { extra.append(.compactionActivity(compactionActivity)) }
        return (items + extra).sorted {
            $0.orderedAt == $1.orderedAt
                ? $0.sortRank < $1.sortRank : $0.orderedAt < $1.orderedAt
        }
    }

    // MARK: - Compaction

    /// What a compaction would summarize, or `nil` when there is not enough
    /// history to be worth it.
    func compactionSpan(
        keepRecentTokens: Int = AgentCompaction.defaultKeepRecentTokens
    ) -> (summarize: [AgentTranscriptMessage], cut: Int)? {
        guard
            let cut = AgentCompaction.cutIndex(
                in: transcript, keepRecentTokens: keepRecentTokens
            )
        else { return nil }
        return (Array(transcript[..<cut]), cut)
    }

    func beginCompaction() {
        isCompacting = true
        compactionActivity = AgentCompactionActivity(state: .running)
    }

    func endCompaction() {
        isCompacting = false
        compactionActivity = nil
    }

    func failCompaction(_ reason: String) {
        isCompacting = false
        if var activity = compactionActivity {
            activity.state = .failed(reason)
            compactionActivity = activity
        } else {
            compactionActivity = AgentCompactionActivity(state: .failed(reason))
        }
    }

    /// Replaces everything before `cut` with one synthetic turn carrying the
    /// summary.
    ///
    /// `transcript` — what the model is sent — is rewritten. `messages` — what
    /// the reader sees — is not: a marker is added instead, so the conversation
    /// stays scrollable and nothing the user wrote disappears. That is the same
    /// rule `AgentContextPipeline` states for every other transform.
    func applyCompaction(summary: String, cut: Int) {
        guard cut > 0, cut <= transcript.count else { return }
        let summarized = transcript[..<cut]
        let summarizedTokens = summarized.reduce(0) {
            $0 + AgentContextEstimator.tokens(inCharacters: $1.text.count)
        }
        // Anchored to the *last summarized* message rather than the first kept
        // one. `appendUserTurn` writes the visible `ChatMessage` a moment before
        // the `AgentTranscriptMessage` beside it, so anchoring forward and
        // subtracting an epsilon is a coin flip between the two lists whenever
        // turns land close together. Anchoring backward is exact: everything
        // summarized was stamped at or before this, and everything kept after.
        let stamp = transcript[cut - 1].createdAt
        let replacement = AgentTranscriptMessage(
            role: .user, text: summary, isCompaction: true, createdAt: stamp
        )
        transcript.replaceSubrange(..<cut, with: [replacement])
        compactions.append(
            AgentCompactionMark(
                summarizedTokens: summarizedTokens,
                keptTokens: AgentContextEstimator.tokens(inCharacters: summary.count),
                createdAt: stamp
            ))
        // The gauge is measuring a context that no longer exists. Dropping it
        // rather than scaling it means the next turn reports a real number and
        // until then the estimate is shown as an estimate.
        usage = nil
    }

    /// Records what the user decided about a plan.
    ///
    /// Implementing turns plan mode off, because that is what the decision
    /// means: the next run is the one that acts. Keeping the mode on after
    /// "Implement" would refuse every tool the plan asked for.
    func resolvePlan(_ id: AgentPlan.ID, as outcome: AgentPlan.Outcome) {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        plans[index].outcome = outcome
        if outcome == .implemented { isPlanning = false }
    }

    /// What starting the implementation run should send.
    ///
    /// The plan itself is already in `transcript` — `present_plan` returned it —
    /// so this is a pointer, not a copy. Naming the scratch path lets the model
    /// re-read the exact text rather than work from what it remembers writing.
    static func implementationPrompt(for plan: AgentPlan) -> String {
        String(
            localized: """
                Implement the plan you presented ("\(plan.title)", drafted at \
                \(plan.scratchPath)). Follow it; if something you find contradicts it, say so \
                before departing from it.
                """
        )
    }

    func attach(_ chip: ContextChip) {
        guard !attachments.contains(where: {
            if let image = chip.image, let existing = $0.image {
                return existing.data == image.data
            }
            return $0.kind == chip.kind && $0.content == chip.content
        })
        else { return }
        attachments.append(chip)
    }

    func detach(_ id: ContextChip.ID) {
        attachments.removeAll { $0.id == id }
    }

    func beginAttachmentImport(label: String) -> PendingContextAttachment? {
        guard attachments.count + pendingAttachments.count < ContextAttachmentImporter.maximumAttachments
        else {
            attachmentImportError = String(localized: "A message can include at most 20 attachments.")
            return nil
        }
        let pending = PendingContextAttachment(label: label)
        pendingAttachments.append(pending)
        return pending
    }

    func finishAttachmentImport(_ id: PendingContextAttachment.ID, with chip: ContextChip) {
        guard pendingAttachments.contains(where: { $0.id == id }) else { return }
        pendingAttachments.removeAll { $0.id == id }
        attach(chip)
    }

    func failAttachmentImport(_ id: PendingContextAttachment.ID, message: String) {
        guard pendingAttachments.contains(where: { $0.id == id }) else { return }
        pendingAttachments.removeAll { $0.id == id }
        attachmentImportError = [attachmentImportError, message]
            .compactMap { $0 }.joined(separator: "\n")
    }

    func cancelAttachmentImport(_ id: PendingContextAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Records a local user turn. Agent-backed composers use AppModel's runtime
    /// path; the sidebar promotion flow uses this before starting that run.
    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        appendUserTurn(text)
        draft = ""
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
    func appendUserTurn(_ text: String) -> String {
        appendUserTurnContent(text).text
    }

    struct ComposedUserTurn: Sendable {
        var id: UUID
        var text: String
        var authoredText: String
        var images: [AgentImageAttachment]
    }

    @discardableResult
    func appendUserTurnContent(_ text: String) -> ComposedUserTurn {
        let composed = composed(text)
        let messageID = UUID()
        let contextChips = attachments.map {
            ContextChipReference(id: $0.id, kind: $0.kind, label: $0.label)
        }
        attachments.removeAll()
        messages.append(
            ChatMessage(
                id: messageID, role: .user, text: text,
                contextChips: contextChips, images: composed.images
            )
        )
        transcript.append(
            AgentTranscriptMessage(
                id: messageID, role: .user, text: composed.text,
                authoredText: text, images: composed.images
            )
        )
        updatedAt = .now
        return ComposedUserTurn(
            id: messageID, text: composed.text, authoredText: text, images: composed.images
        )
    }

    /// Renders attachments into the model-facing message body. The visible
    /// `ChatMessage` deliberately keeps only the prompt: extracted documents
    /// and pasted text can be hundreds of thousands of characters and do not
    /// belong in a Markdown bubble.
    private func composed(_ text: String) -> ComposedUserTurn {
        guard !attachments.isEmpty else {
            return ComposedUserTurn(id: UUID(), text: text, authoredText: text, images: [])
        }
        let blocks = attachments.compactMap { chip -> String? in
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
        return ComposedUserTurn(
            id: UUID(), text: ([text] + blocks).joined(separator: "\n\n"),
            authoredText: text,
            images: attachments.compactMap(\.image)
        )
    }

    /// The history to replay for a run whose prompt is the last user turn.
    var pendingPriorMessages: [AgentTranscriptMessage] {
        guard let last = transcript.lastIndex(where: { $0.role == .user }),
            last == transcript.index(before: transcript.endIndex)
        else { return transcript }
        return Array(transcript[..<last])
    }

    /// Takes ownership of a run before it can emit its first event. Keeping the
    /// runtime and its consumer together prevents an immediately-completing
    /// provider response from racing the UI attachment path.
    func start(runtime: AgentRuntime, request: AgentRunRequest) {
        self.runtime = runtime
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            let events = await runtime.start(request)
            for await event in events {
                guard let self else { return }
                handle(event)
            }
        }
    }

    func stop() {
        settleStreamingPresentation(for: activeRunID)
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
        if !runtimeState.isTerminal {
            runtimeState = .cancelled
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
        refreshRunState()
    }

    /// Queues the draft for the running agent instead of starting a second run.
    ///
    /// Nothing reaches `messages` or `transcript` here. A bubble posted at the
    /// keystroke sits above the assistant text that actually preceded it, and
    /// `transcript` is replayed as the next run's history — so the model would
    /// later be shown a conversation that never happened. The bubble appears
    /// when the runtime reports the message delivered, which is where the model
    /// really saw it.
    func submitSteeringDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let runtime else { return }
        let composed = composed(text)
        let pending = PendingSteeringMessage(
            draft: text, attachments: attachments,
            message: AgentTranscriptMessage(
                role: .user, text: composed.text, authoredText: text,
                images: composed.images
            )
        )
        pendingSteering.append(pending)
        attachments.removeAll()
        draft = ""
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
    func returnSteeringToDraft(_ id: AgentTranscriptMessage.ID) {
        guard let index = pendingSteering.firstIndex(where: { $0.id == id }) else { return }
        let pending = pendingSteering.remove(at: index)
        draft = [pending.draft, draft].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
    func requestApproval(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
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
        refreshRunState()
        return await withCheckedContinuation { approvalWaiters[request.id] = $0 }
    }

    func respondToApproval(allow: Bool) {
        guard !pendingApprovals.isEmpty else { return }
        let request = pendingApprovals.removeFirst()
        let decision: AgentApprovalDecision =
            allow
            ? .allow : .deny(String(localized: "The user denied this action."))
        if !allow { setToolState(request.invocation.id, .denied) }
        refreshRunState()
        approvalWaiters.removeValue(forKey: request.id)?.resume(returning: decision)
    }

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
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

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        pendingSSHAuthentications.append(request)
        setToolState(request.invocationID, .waitingForUser)
        refreshRunState()
        return await withCheckedContinuation {
            sshAuthenticationWaiters[request.id] = $0
        }
    }

    func respondToSSHAuthentication(_ response: AgentSSHAuthenticationResponse) {
        guard !pendingSSHAuthentications.isEmpty else { return }
        let request = pendingSSHAuthentications.removeFirst()
        setToolState(request.invocationID, .running)
        refreshRunState()
        sshAuthenticationWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    /// Puts a question on screen. The queue path uses it, and so does any
    /// caller that wants the card without a run behind it.
    func present(_ request: AgentUserInputRequest) {
        pendingUserInputs.append(request)
        // Only the head is being answered, so only the head's drafts exist. A
        // queued question gets a blank sheet when it reaches the front.
        if pendingUserInputs.count == 1 {
            clearUserInputDrafts()
            scheduleUserInputTimeout()
        }
        refreshRunState()
    }

    func userInputDraft(for questionID: String) -> AgentUserInputDraft {
        userInputDrafts[questionID] ?? AgentUserInputDraft()
    }

    /// Whether this one question has been answered. Skipping is allowed, so
    /// this drives a count rather than a validation error.
    func isUserInputAnswered(_ question: AgentUserQuestion) -> Bool {
        switch question.kind {
        case .secret: return !secretInputDraft.isEmpty
        default:
            let draft = userInputDraft(for: question.id)
            return !draft.selection.isEmpty || !draft.trimmedText.isEmpty
        }
    }

    var answeredUserInputCount: Int {
        pendingUserInput?.questions.filter(isUserInputAnswered).count ?? 0
    }

    var currentUserInputQuestion: AgentUserQuestion? {
        guard let questions = pendingUserInput?.questions,
            questions.indices.contains(currentUserInputQuestionIndex)
        else { return nil }
        return questions[currentUserInputQuestionIndex]
    }

    var canAdvanceUserInput: Bool {
        guard let question = currentUserInputQuestion else { return false }
        return isUserInputAnswered(question) || skippedUserInputQuestionIDs.contains(question.id)
    }

    var canSubmitUserInput: Bool {
        guard let request = pendingUserInput else { return false }
        return currentUserInputQuestionIndex == request.questions.count - 1 && canAdvanceUserInput
    }

    var canSkipUserInputQuestion: Bool {
        guard let question = currentUserInputQuestion else { return false }
        if case .secret = question.kind { return false }
        return true
    }

    func toggleUserInputOption(_ optionID: String, in questionID: String) {
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

    /// The other half of that rule — typing clears the radio it would otherwise
    /// silently disagree with. Left alone in a multi-answer question, where the
    /// two are additive rather than exclusive.
    func setUserInputCustomAnswer(_ text: String, for questionID: String) {
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

    func advanceUserInputQuestion() {
        guard let request = pendingUserInput, canAdvanceUserInput else { return }
        if currentUserInputQuestionIndex == request.questions.count - 1 {
            submitUserInput()
        } else {
            currentUserInputQuestionIndex += 1
        }
    }

    func previousUserInputQuestion() {
        guard currentUserInputQuestionIndex > 0 else { return }
        currentUserInputQuestionIndex -= 1
    }

    func skipUserInputQuestion() {
        guard let question = currentUserInputQuestion, canSkipUserInputQuestion else { return }
        userInputDrafts[question.id] = AgentUserInputDraft()
        skippedUserInputQuestionIDs.insert(question.id)
        advanceUserInputQuestion()
    }

    func submitUserInput() {
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

    func cancelUserInput() {
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
        refreshRunState()
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
            refreshRunState()
        }
        inputWaiters.removeValue(forKey: id)?.resume(returning: .cancelled)
    }

    private func scheduleUserInputTimeout() {
        userInputTimeoutTask?.cancel()
        guard let request = pendingUserInput else {
            userInputTimeoutTask = nil
            return
        }
        userInputTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: request.timeout)
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

    /// What the transcript shows, from what is actually outstanding.
    ///
    /// Assigning run state at each event only worked while one thing happened
    /// at a time. With a batch in flight, the tool whose review just finished
    /// would announce `running` while another was still waiting on the user, so
    /// the composer unlocked over an unanswered question. Ranked instead: a
    /// person being waited on outranks a review, which outranks the run's own
    /// idea of itself, and a terminal state outranks everything.
    private func refreshRunState() {
        if runtimeState.isTerminal || runtimeState == .idle {
            runState = runtimeState
        } else if !pendingUserInputs.isEmpty || !pendingSSHAuthentications.isEmpty {
            runState = .waitingForUser
        } else if !pendingApprovals.isEmpty {
            runState = .waitingForApproval
        } else if !reviewing.isEmpty {
            runState = .reviewing
        } else {
            runState = runtimeState
        }
        if let activeRunID, var summary = runSummaries[activeRunID] {
            summary.state = runState
            runSummaries[activeRunID] = summary
        }
        isStreaming = runState != .idle && !runState.isTerminal
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
        activeReasoningMessageID = nil
        for index in messages.indices where messages[index].isStreaming {
            guard runID == nil || messageRunIDs[messages[index].id] == runID else {
                continue
            }
            messages[index].isStreaming = false
        }
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .runState(let state):
            runtimeState = state
            if state.isTerminal { settleStreamingPresentation(for: activeRunID) }
            refreshRunState()
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
            settleStreamingPresentation(for: run.id)
            runSummaries[run.id] = run
            if activeRunID == run.id { activeRunID = nil }
        case .turnStarted:
            activeReasoningMessageID = nil
        case .turnFinished:
            activeReasoningMessageID = nil
        case .messageStarted(let started):
            activeReasoningMessageID = nil
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
            refreshRunState()
        case .messageDelta(let id, let text):
            if let activeRunID { messageRunIDs[id] = activeRunID }
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += text
                messages[index].isStreaming = true
            } else {
                messages.append(
                    ChatMessage(
                        id: id, role: .assistant, text: text, isStreaming: true
                    ))
            }
            refreshRunState()
        case .reasoningDelta(let id, let text):
            activeReasoningMessageID = id
            if let activeRunID { messageRunIDs[id] = activeRunID }
            if let index = messages.firstIndex(where: { $0.id == id }) {
                if messages[index].reasoning.isEmpty {
                    messages[index].reasoning.append(AgentReasoningBlock(
                        text: text, createdAt: messages[index].createdAt
                    ))
                } else {
                    messages[index].reasoning[
                        messages[index].reasoning.index(before: messages[index].reasoning.endIndex)
                    ].text += text
                }
                messages[index].isStreaming = true
            }
            refreshRunState()
        // A queued turn has entered the model's context, so now it is part of
        // the conversation — in both lists, at the position the run put it, and
        // no longer in the queue the composer is drawing.
        case .steeringDelivered(let message):
            if let activeRunID { messageRunIDs[message.id] = activeRunID }
            let pending = pendingSteering.first(where: { $0.id == message.id })
            let visibleText = pending?.draft ?? ContextChip.visiblePrompt(in: message.text)
            let contextChips = pending?.attachments.map {
                ContextChipReference(id: $0.id, kind: $0.kind, label: $0.label)
            } ?? ContextChip.visibleReferences(in: message.text, images: message.images)
            pendingSteering.removeAll { $0.id == message.id }
            messages.append(
                ChatMessage(
                    id: message.id, role: .user, text: visibleText,
                    contextChips: contextChips, images: message.images,
                    createdAt: message.createdAt
                ))
            transcript.append(message)
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
            updatedAt = .now
        case .toolProposed(let invocation, let descriptor):
            toolCards.append(AgentToolCard(invocation: invocation, descriptor: descriptor))
        case .toolStarted(let invocation): setToolState(invocation.id, .running)
        // The card only, and the card's state is left alone: this is a call
        // still running, showing its work. Nothing here reaches `transcript` —
        // the model is owed one result per call, and it gets that from
        // `toolFinished`.
        case .toolProgress(let invocation, let partial):
            if let index = toolCards.firstIndex(where: { $0.id == invocation.id }) {
                toolCards[index].result = partial
            }
        case .toolFinished(let invocation, let result):
            if let index = toolCards.firstIndex(where: { $0.id == invocation.id }) {
                toolCards[index].result = result
                // A denied call did not fail — someone said no. The denial is
                // an error to the *model*, which is what makes the turn
                // replayable, but the card kept being relabelled `Failed` the
                // instant it was refused, so `denied` never reached the screen.
                if toolCards[index].state != .denied {
                    if result.isInterrupted {
                        toolCards[index].state = .interrupted
                    } else {
                        toolCards[index].state = result.isError ? .failed : .completed
                    }
                }
            }
            // A card, but not a turn. A provider-native search happened inside
            // the assistant's own turn and was never a tool call here, so
            // adding it to the model-facing transcript would replay a tool
            // result the provider has no matching call for — which it rejects
            // on the *next* request. See `AgentToolResult.isProviderNative`.
            guard !result.isProviderNative else { break }
            transcript.append(
                AgentTranscriptMessage(
                    role: .tool, text: result.content, toolCallID: result.callID,
                    toolName: invocation.call.name, isError: result.isError
                ))
        // The card only. The queue belongs to `requestApproval`, which is the
        // path that also holds the continuation — see its comment.
        case .approvalRequested(let request):
            setToolState(request.invocation.id, .waitingForApproval)
        case .reviewStarted(let request):
            reviewing.insert(request.invocation.id)
            setToolState(request.invocation.id, .reviewing)
            refreshRunState()
        case .reviewFinished(let request, let decision):
            reviewing.remove(request.invocation.id)
            if let index = toolCards.firstIndex(where: { $0.id == request.invocation.id }) {
                toolCards[index].review = decision
            }
            refreshRunState()
        case .reviewFailed(let request, _, _):
            reviewing.remove(request.invocation.id)
            setToolState(request.invocation.id, .failed)
            refreshRunState()
        // Also card-only. `request(_:)` enqueues, for the same reason.
        case .userInputRequested:
            break
        case .usageUpdated(let reported):
            usage = reported
        case .planPresented(let plan):
            plans.append(AgentPlanCard(plan: plan))
        case .tasksUpdated(let updated):
            tasks = updated
        case .failed(let reason):
            messages.append(ChatMessage(role: .assistant, text: reason))
        }
    }

    private func setToolState(_ id: UUID, _ state: AgentToolCard.State) {
        guard let index = toolCards.firstIndex(where: { $0.id == id }) else { return }
        toolCards[index].state = state
    }

    /// Adds a final speech-recognition result without disturbing text the user
    /// already wrote. The callback keeps the standalone composer and the
    /// sidebar's "promote draft to conversation" path on the same behavior.
    @discardableResult
    func applyTranscription(
        _ transcript: String,
        sendAfterTranscription: Bool,
        send: () -> Void
    ) -> Bool {
        let cleaned = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return false }

        if draft.isEmpty {
            draft = cleaned
        } else if draft.last?.isWhitespace == true {
            draft += cleaned
        } else {
            draft += " " + cleaned
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
final class WeakAgentUserInteraction {
    private weak var conversation: ConversationModel?

    init(_ conversation: ConversationModel) {
        self.conversation = conversation
    }

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        guard let conversation else { return .cancelled }
        return await conversation.request(request)
    }

    func requestSSHAuthentication(
        _ request: AgentSSHAuthenticationRequest
    ) async -> AgentSSHAuthenticationResponse {
        guard let conversation else { return .cancelled }
        return await conversation.requestSSHAuthentication(request)
    }
}

extension WeakAgentUserInteraction: AgentUserInteractionHandling {}

// MARK: - Demo data

extension ConversationModel {
    static func demo() -> ConversationModel {
        let conversation = ConversationModel()
        conversation.attach(
            ContextChip(
                kind: .output, label: "Last 200 lines",
                content: String(repeating: "nginx: connect() failed\n", count: 200)
            ))
        conversation.messages = [
            ChatMessage(role: .user, text: "Root is at 99%. What is eating the space?"),
            ChatMessage(
                role: .assistant,
                text:
                    "`df` shows `/` at 99% while `/data` has room, so the growth is on the root volume. Start by finding the biggest directory under `/var`, which is where logs and package caches accumulate.",
                commands: [
                    SuggestedCommand(
                        command: "du -sh /var/* | sort -h",
                        explanation: "Read-only. Lists each directory under /var by size."
                    ),
                    SuggestedCommand(
                        command: "rm -rf /var/log/nginx/*.gz",
                        explanation: "Deletes rotated nginx logs. Roughly 2.1 GB, unrecoverable."
                    ),
                ]
            ),
        ]
        return conversation
    }
}

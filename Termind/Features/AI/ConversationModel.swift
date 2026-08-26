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
        case host, directory, output, selection, file

        var symbol: String {
            switch self {
            case .host: "server.rack"
            case .directory: "folder"
            case .output: "text.alignleft"
            case .selection: "text.cursor"
            case .file: "doc"
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
            }
        }
    }

    var id: UUID = UUID()
    var kind: Kind
    var label: String
    var content: String = ""

    /// Derived, not declared. A hand-passed count is a number that was true
    /// once, and the estimate exists to warn about payload size.
    var approximateTokens: Int { max(1, content.count / 4) }
}

nonisolated struct ChatMessage: Identifiable, Hashable, Sendable {
    nonisolated enum Role: Hashable, Sendable {
        case user, assistant
    }

    var id: UUID = UUID()
    var role: Role
    var text: String
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
        case proposed, waitingForApproval, reviewing, running, completed, denied, failed

        /// The transcript used to show `rawValue.capitalized`, which put the
        /// case name itself on screen — `WaitingForApproval`. The raw value is
        /// a storage key; this is the label.
        var displayName: String {
            switch self {
            case .proposed: String(localized: "Proposed")
            case .waitingForApproval: String(localized: "Waiting for approval")
            case .reviewing: String(localized: "Reviewing")
            case .running: String(localized: "Running")
            case .completed: String(localized: "Completed")
            case .denied: String(localized: "Denied")
            case .failed: String(localized: "Failed")
            }
        }

        /// Whether a card in this state opens itself.
        ///
        /// Anything still in flight, or anything that went wrong, is what the
        /// reader is actually looking for. A call that simply worked is noise
        /// once it has worked.
        var revealsDetailByDefault: Bool {
            switch self {
            case .waitingForApproval, .reviewing, .running, .denied, .failed: true
            case .proposed, .completed: false
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

/// One row of a conversation, whichever of the two lists it came from.
nonisolated enum TimelineItem: Identifiable, Hashable, Sendable {
    case message(ChatMessage)
    case tool(AgentToolCard)

    var id: UUID {
        switch self {
        case .message(let message): message.id
        case .tool(let card): card.id
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
            hasher.combine(message.isStreaming)
        case .tool(let card):
            hasher.combine(card.state)
            hasher.combine(card.result?.content.count ?? 0)
        }
        return hasher.finalize()
    }
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
    var messages: [ChatMessage] = []
    /// What the user attached by hand, each carrying its own payload. Consumed
    /// by the next user turn: an attachment belongs to one message, and once
    /// that message is sent the content is in the transcript already.
    var attachments: [ContextChip] = []
    var draft: String = ""
    var isStreaming: Bool = false
    var runState: AgentRunState = .idle
    var toolCards: [AgentToolCard] = []
    var pendingApproval: AgentApprovalRequest?
    var pendingUserInput: AgentUserInputRequest?
    var userInputDraft = ""
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

    /// Per-conversation reasoning state, normalized against the resolved model
    /// by the composer before a request is made.
    var reasoningEffort: ReasoningEffort = .medium

    /// An explicit choice for this conversation. `nil` follows the app-wide
    /// last selection through `AIStore.resolve(conversation:)`, the same shape
    /// used by `model` below.
    var permissionMode: ChatPermissionMode?

    /// The model this conversation was told to use, if it was told.
    ///
    /// `nil` is the normal state and is not a missing value — it means "whatever
    /// the Chat role resolves to", which `AIStore.resolve(_:)` answers. Keeping
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
        runState: AgentRunState = .idle
    ) {
        self.id = id
        self.messages = messages
        self.transcript = transcript
        self.runState = runState
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
        if let title, !title.isEmpty { return title }
        guard let first = messages.first(where: { $0.role == .user }) else {
            return String(localized: "New Chat")
        }
        let line = first.text.split(separator: "\n").first.map(String.init) ?? first.text
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    var isEmpty: Bool { messages.isEmpty }

    /// Messages and tool cards in the order they happened.
    ///
    /// Drawing the two lists one after the other put every tool card below
    /// every message, so a run that alternated between talking and acting read
    /// back as a wall of text followed by a wall of cards. Both lists are
    /// already chronological, so this is a merge rather than a sort.
    var timeline: [TimelineItem] {
        var items: [TimelineItem] = []
        items.reserveCapacity(messages.count + toolCards.count)
        var cards = toolCards[...]
        for message in messages {
            while let card = cards.first, card.invocation.createdAt < message.createdAt {
                items.append(.tool(card))
                cards = cards.dropFirst()
            }
            // A turn that only called tools has no text to show, and an empty
            // bubble reads as the model having said nothing. While it is still
            // streaming it stays, because that is the "working" indicator.
            guard message.role != .assistant || !message.text.isEmpty || message.isStreaming
            else { continue }
            items.append(.message(message))
        }
        return items + cards.map(TimelineItem.tool)
    }

    func attach(_ chip: ContextChip) {
        guard !attachments.contains(where: { $0.kind == chip.kind && $0.label == chip.label })
        else { return }
        attachments.append(chip)
    }

    func detach(_ id: ContextChip.ID) {
        attachments.removeAll { $0.id == id }
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
    /// one, folding in whatever was attached, and hands back the text that
    /// actually went.
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
        let composed = composed(text)
        attachments.removeAll()
        messages.append(ChatMessage(role: .user, text: composed))
        transcript.append(AgentTranscriptMessage(role: .user, text: composed))
        return composed
    }

    /// Renders attachments into the message body rather than smuggling them
    /// past it. What was uploaded is then literally what the bubble shows,
    /// which is the BYOK rule the chips exist to serve, and it costs no hidden
    /// message kind in the transcript or its stored schema.
    private func composed(_ text: String) -> String {
        guard !attachments.isEmpty else { return text }
        let blocks = attachments.map { chip in
            // A label can be a filename, and a filename can contain a quote —
            // which would close the attribute and leave the block malformed.
            let label = chip.label.replacingOccurrences(of: "\"", with: "'")
            return """
                <\(chip.kind.blockName) label="\(label)">
                \(chip.content)
                </\(chip.kind.blockName)>
                """
        }
        return ([text] + blocks).joined(separator: "\n\n")
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
        eventTask?.cancel()
        eventTask = nil
        // Read the runtime *before* releasing it. `Task { await runtime?… }`
        // resolves the property when the task runs, which is after this method
        // has already set it to nil — so the run kept executing tools with
        // nobody listening.
        if let runtime { Task { await runtime.cancel() } }
        runtime = nil
        isStreaming = false
        if !runState.isTerminal { runState = .cancelled }
    }

    func steer(_ text: String) {
        guard let runtime else { return }
        Task { await runtime.steer(text) }
    }

    /// Queues a visible user turn for the next model boundary without replacing
    /// the active runtime or interrupting an in-flight tool.
    func submitSteeringDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runtime != nil else { return }
        appendUserTurn(text)
        draft = ""
        steer(text)
    }

    func requestApproval(_ request: AgentApprovalRequest) async -> AgentApprovalDecision {
        pendingApproval = request
        runState = .waitingForApproval
        setToolState(request.invocation.id, .waitingForApproval)
        return await withCheckedContinuation { approvalWaiters[request.id] = $0 }
    }

    func respondToApproval(allow: Bool) {
        guard let request = pendingApproval else { return }
        pendingApproval = nil
        runState = .running
        let decision: AgentApprovalDecision = allow
            ? .allow : .deny(String(localized: "The user denied this action."))
        if !allow { setToolState(request.invocation.id, .denied) }
        approvalWaiters.removeValue(forKey: request.id)?.resume(returning: decision)
    }

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        pendingUserInput = request
        userInputDraft = ""
        secretInputDraft = ""
        runState = .waitingForUser
        return await withCheckedContinuation { inputWaiters[request.id] = $0 }
    }

    func submitUserInput() {
        guard let request = pendingUserInput else { return }
        let response: AgentUserInputResponse
        switch request.kind {
        case .secret: response = .secret(secretInputDraft)
        case .text, .choice: response = .text(userInputDraft)
        }
        secretInputDraft = ""
        userInputDraft = ""
        pendingUserInput = nil
        runState = .running
        inputWaiters.removeValue(forKey: request.id)?.resume(returning: response)
    }

    func cancelUserInput() {
        guard let request = pendingUserInput else { return }
        secretInputDraft = ""
        userInputDraft = ""
        pendingUserInput = nil
        inputWaiters.removeValue(forKey: request.id)?.resume(returning: .cancelled)
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .runState(let state):
            runState = state
            isStreaming = state != .idle && !state.isTerminal
            if state.isTerminal { runDidFinish?() }
        case .messageStarted(let id):
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].isStreaming = true
            } else {
                messages.append(ChatMessage(id: id, role: .assistant, text: "", isStreaming: true))
            }
            isStreaming = true
        case .messageDelta(let id, let text):
            if let index = messages.firstIndex(where: { $0.id == id }) {
                messages[index].text += text
                messages[index].isStreaming = true
            } else {
                messages.append(ChatMessage(
                    id: id, role: .assistant, text: text, isStreaming: true
                ))
            }
            isStreaming = true
        case .messageFinished(let message):
            if let index = messages.firstIndex(where: { $0.id == message.id }) {
                messages[index].text = message.text
                messages[index].isStreaming = false
            } else {
                messages.append(ChatMessage(
                    id: message.id, role: .assistant, text: message.text,
                    isStreaming: false
                ))
            }
            // Whole message, not just its text: the tool calls and the opaque
            // provider items are what the next turn has to replay.
            if let index = transcript.firstIndex(where: { $0.id == message.id }) {
                transcript[index] = message
            } else {
                transcript.append(message)
            }
        case .toolProposed(let invocation, let descriptor):
            toolCards.append(AgentToolCard(invocation: invocation, descriptor: descriptor))
        case .toolStarted(let invocation): setToolState(invocation.id, .running)
        case .toolFinished(let invocation, let result):
            if let index = toolCards.firstIndex(where: { $0.id == invocation.id }) {
                toolCards[index].result = result
                toolCards[index].state = result.isError ? .failed : .completed
            }
            // A card, but not a turn. A provider-native search happened inside
            // the assistant's own turn and was never a tool call here, so
            // adding it to the model-facing transcript would replay a tool
            // result the provider has no matching call for — which it rejects
            // on the *next* request. See `AgentToolResult.isProviderNative`.
            guard !result.isProviderNative else { break }
            transcript.append(AgentTranscriptMessage(
                role: .tool, text: result.content, toolCallID: result.callID,
                toolName: invocation.call.name, isError: result.isError
            ))
        case .approvalRequested(let request):
            pendingApproval = request
            setToolState(request.invocation.id, .waitingForApproval)
        case .reviewStarted(let request):
            runState = .reviewing
            setToolState(request.invocation.id, .reviewing)
        case .reviewFinished(let request, let decision):
            runState = .running
            if let index = toolCards.firstIndex(where: { $0.id == request.invocation.id }) {
                toolCards[index].review = decision
            }
        case .reviewFailed(let request, _, _):
            runState = .running
            setToolState(request.invocation.id, .failed)
        case .userInputRequested(let request): pendingUserInput = request
        case .failed(let reason):
            messages.append(ChatMessage(role: .assistant, text: reason))
            isStreaming = false
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
}

extension WeakAgentUserInteraction: AgentUserInteractionHandling {}

// MARK: - Demo data

extension ConversationModel {
    static func demo() -> ConversationModel {
        let conversation = ConversationModel()
        conversation.attach(ContextChip(
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

import Foundation

nonisolated struct AgentModelRequest: Sendable {
    var systemPrompt: String
    var messages: [AgentTranscriptMessage]
    var tools: [AgentToolDescriptor]
}

nonisolated enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    /// Authoritative complete text used by buffered/final provider responses.
    case textSnapshot(String)
    case toolCallDelta(id: String, name: String?, arguments: String)
    /// The authoritative completed tool call. Arguments replace, rather than
    /// append to, the partial streaming buffer.
    case toolCallSnapshot(
        id: String, providerItemID: String?, name: String, arguments: String
    )
    case providerItem(AgentJSONValue)
    case finished(AgentStopReason)
}

nonisolated protocol AgentModelStreaming: Sendable {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error>
}

/// A single buffered model response. Short, tool-free features use this path so
/// their success does not depend on SSE framing or a provider-specific [DONE]
/// event.
nonisolated protocol AgentModelCompleting: Sendable {
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent]
}

nonisolated struct AgentToolExecutionContext: Sendable {
    var runID: UUID
    var userIntent: String
    var secretBroker: SecretBroker
    var userInteraction: any AgentUserInteractionHandling
    var preflightMetadata: [String: AgentJSONValue]
    var authorize: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
}

nonisolated private struct EventingAgentUserInteraction: AgentUserInteractionHandling, Sendable {
    var base: any AgentUserInteractionHandling
    var event: @Sendable (AgentEvent) async -> Void

    func request(_ request: AgentUserInputRequest) async -> AgentUserInputResponse {
        await event(.userInputRequested(request))
        await event(.runState(.waitingForUser))
        let response = await base.request(request)
        await event(.runState(.running))
        return response
    }
}

nonisolated protocol AgentTool: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight
    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult
}

nonisolated extension AgentTool {
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
    }
}

nonisolated struct AnyAgentTool: AgentTool, Sendable {
    let descriptor: AgentToolDescriptor
    private let executeClosure:
        @Sendable (AgentToolInvocation, AgentToolExecutionContext) async throws -> AgentToolResult
    private let preflightClosure: @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight

    init<T: AgentTool>(_ tool: T) {
        descriptor = tool.descriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    init(
        descriptor: AgentToolDescriptor,
        preflight: (@Sendable (AgentToolInvocation) async throws -> AgentToolPreflight)? = nil,
        execute: @escaping @Sendable (
            AgentToolInvocation, AgentToolExecutionContext
        ) async throws -> AgentToolResult
    ) {
        self.descriptor = descriptor
        preflightClosure = preflight ?? { invocation in
            AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
        }
        executeClosure = execute
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        try await preflightClosure(invocation)
    }

    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        try await executeClosure(invocation, context)
    }
}

nonisolated protocol AgentRunPersisting: Sendable {
    func save(_ snapshot: AgentRunSnapshot) async throws
    func record(_ event: AgentEvent, runID: UUID) async throws
    func loadConversations() async throws -> [StoredAgentConversation]
    func deleteConversation(_ id: UUID) async throws
    /// Records the generated summary. Separate from `save` because it arrives
    /// after the run that produced it has already been written, and because a
    /// run snapshot is not where a name for the whole conversation belongs.
    func setTitle(_ title: String, conversationID: UUID) async throws
}

// No default implementations here, deliberately. A protocol extension that
// satisfies a requirement is also the thing that *silently* satisfies it when a
// conformer's own method stops being a valid witness — an isolation change, a
// renamed label — and run history would then be dropped with no diagnostic.
// Both conformers implement the whole protocol.

nonisolated struct StoredAgentConversation: Sendable {
    var id: UUID
    var messages: [AgentTranscriptMessage]
    var toolCards: [StoredAgentToolCard] = []
    var lastRunState: AgentRunState
    /// The generated summary, or empty for a conversation that never got one.
    var title: String = ""
}

nonisolated struct StoredAgentToolCard: Sendable {
    var invocation: AgentToolInvocation
    var descriptor: AgentToolDescriptor
    var state: String
    var result: AgentToolResult?
    var review: SecurityReviewDecision?
}

actor InMemoryAgentRunRepository: AgentRunPersisting {
    private var snapshots: [UUID: AgentRunSnapshot] = [:]
    private var titles: [UUID: String] = [:]
    private var deletedConversationIDs = Set<UUID>()
    func save(_ snapshot: AgentRunSnapshot) {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else { return }
        snapshots[snapshot.id] = snapshot
    }
    func record(_ event: AgentEvent, runID: UUID) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func snapshot(_ id: UUID) -> AgentRunSnapshot? { snapshots[id] }
    func setTitle(_ title: String, conversationID: UUID) {
        guard !deletedConversationIDs.contains(conversationID) else { return }
        titles[conversationID] = title
    }
    func title(_ conversationID: UUID) -> String? { titles[conversationID] }
    func deleteConversation(_ id: UUID) {
        deletedConversationIDs.insert(id)
        titles.removeValue(forKey: id)
        snapshots = snapshots.filter { $0.value.conversationID != id }
    }
}

/// Low-level Pi-style loop: stream one assistant turn, collect complete tool calls,
/// authorize and execute them in source order, append results, then ask the model again.
actor AgentRuntime {
    private struct PendingToolCall {
        var name = ""
        var arguments = ""
        var providerItemID: String?
    }

    private let model: any AgentModelStreaming
    private let approval: any AgentApprovalHandling
    private let repository: any AgentRunPersisting
    private let userInteraction: any AgentUserInteractionHandling
    let secretBroker: SecretBroker
    private var tools: [String: AnyAgentTool]
    private var runTask: Task<Void, Never>?
    private var steering: [AgentTranscriptMessage] = []
    private var continuation: AsyncStream<AgentEvent>.Continuation?
    private var activeRunID: UUID?
    private let maxTurns: Int
    private let maxToolCalls: Int

    init(
        model: any AgentModelStreaming,
        tools: [AnyAgentTool],
        approval: any AgentApprovalHandling,
        repository: any AgentRunPersisting = InMemoryAgentRunRepository(),
        secretBroker: SecretBroker = SecretBroker(),
        userInteraction: any AgentUserInteractionHandling = UnavailableAgentUserInteraction(),
        maxTurns: Int = 24,
        maxToolCalls: Int = 64
    ) {
        self.model = model
        // First registration wins. `uniqueKeysWithValues` traps on a duplicate,
        // and one MCP server whose two tool names sanitize to the same string is
        // enough to take the app down — from data a remote server controls. The
        // built-ins are registered first, so a remote name can never shadow one.
        self.tools = Dictionary(
            tools.map { ($0.descriptor.name, $0) }, uniquingKeysWith: { first, _ in first }
        )
        self.approval = approval
        self.repository = repository
        self.secretBroker = secretBroker
        self.userInteraction = userInteraction
        self.maxTurns = maxTurns
        self.maxToolCalls = maxToolCalls
    }

    func start(_ request: AgentRunRequest) -> AsyncStream<AgentEvent> {
        cancel()
        // Whoever was reading the previous run is about to be orphaned by the
        // reassignment below; end their sequence rather than leaving it
        // suspended for the life of the process.
        continuation?.finish()
        let stream = AsyncStream<AgentEvent> { continuation in
            self.continuation = continuation
        }
        runTask = Task { [weak self] in
            await self?.run(request)
        }
        return stream
    }

    func steer(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        steering.append(AgentTranscriptMessage(role: .user, text: trimmed))
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
        if let runID = activeRunID { Task { await secretBroker.discardSecrets(for: runID) } }
    }

    private func emit(_ event: AgentEvent) {
        continuation?.yield(event)
        // Only run-scoped events reach storage. Handing every event to the
        // repository meant one unstructured task and one `ModelContext.save()`
        // per streamed token, all of it on the main actor — the UI stalled
        // while a reply arrived, and none of those writes recorded anything.
        guard let runID = activeRunID, event.isDurable else { return }
        Task { try? await repository.record(event, runID: runID) }
    }

    /// Puts the session context into what is *sent* without putting it into
    /// what is *kept*.
    ///
    /// `snapshot.messages` is the durable transcript, so a context block added
    /// there would be persisted, replayed, and — since restore projects user
    /// rows into the visible list — eventually shown in the user's own chat
    /// bubble. Dropping it costs the next run one uncached message at the tail
    /// and nothing before it, because history the model already saw is
    /// unchanged either way.
    private static func injecting(
        _ context: AgentTranscriptMessage?,
        at index: Int,
        into messages: [AgentTranscriptMessage]
    ) -> [AgentTranscriptMessage] {
        guard let context, index <= messages.count else { return messages }
        var result = messages
        result.insert(context, at: index)
        return result
    }

    private func run(_ request: AgentRunRequest) async {
        var snapshot = AgentRunSnapshot(
            conversationID: request.conversationID,
            state: .running,
            permissionMode: request.permissionMode,
            messages: request.priorMessages
        )
        activeRunID = snapshot.id
        let runID = snapshot.id
        // Session context rides the tail of the message list, not the system
        // prompt. Every cache these providers keep is a *prefix* cache, and the
        // working directory of a terminal is the most volatile thing we know:
        // one `cd` between turns used to change byte zero of the request and
        // miss the entire replayed conversation. Here the divergence is the
        // newest turn, which was never cacheable anyway, and the system prompt
        // stays byte-identical across every run, conversation, and user.
        let sessionContext = request.sessionContext.modelContext.map {
            AgentTranscriptMessage(role: .user, text: $0)
        }
        // Prior history ends here, and everything a run appends — tool results,
        // steering, assistant turns — goes after the prompt, so this index
        // stays put for the whole run.
        let sessionContextIndex = snapshot.messages.count
        snapshot.messages.append(AgentTranscriptMessage(role: .user, text: request.prompt))
        emit(.runState(.running))
        await persist(snapshot)

        var toolCount = 0
        do {
            for _ in 0..<maxTurns {
                try Task.checkCancellation()
                if !steering.isEmpty {
                    snapshot.messages.append(contentsOf: steering)
                    steering.removeAll()
                }
                let turn = try await assistantTurn(
                    systemPrompt: request.systemPrompt,
                    messages: Self.injecting(
                        sessionContext, at: sessionContextIndex, into: snapshot.messages
                    )
                )
                snapshot.messages.append(turn.message)
                emit(.messageFinished(turn.message))
                await persist(snapshot)

                if turn.reason == .error {
                    throw AgentRuntimeError.providerFailed
                }
                if turn.reason == .length, !turn.message.toolCalls.isEmpty {
                    throw AgentRuntimeError.truncatedToolCall
                }
                guard !turn.message.toolCalls.isEmpty else {
                    snapshot.state = .completed
                    snapshot.finishedAt = .now
                    emit(.runState(.completed))
                    await persist(snapshot)
                    finish(runID: runID)
                    return
                }

                for call in turn.message.toolCalls {
                    try Task.checkCancellation()
                    toolCount += 1
                    guard toolCount <= maxToolCalls else { throw AgentRuntimeError.toolBudgetExceeded }
                    let result = await execute(
                        call,
                        runID: runID,
                        mode: request.permissionMode,
                        userIntent: request.prompt
                    )
                    snapshot.messages.append(
                        AgentTranscriptMessage(
                            role: .tool,
                            text: result.content,
                            toolCallID: result.callID,
                            toolName: call.name,
                            isError: result.isError
                        )
                    )
                    await persist(snapshot)
                }
            }
            throw AgentRuntimeError.turnBudgetExceeded
        } catch is CancellationError {
            snapshot.state = .cancelled
            snapshot.finishedAt = .now
            emit(.runState(.cancelled))
            await persist(snapshot)
        } catch {
            snapshot.state = .failed
            snapshot.failure = error.localizedDescription
            snapshot.finishedAt = .now
            emit(.failed(error.localizedDescription))
            emit(.runState(.failed))
            await persist(snapshot)
        }
        finish(runID: runID)
    }

    private func assistantTurn(
        systemPrompt: String,
        messages: [AgentTranscriptMessage]
    ) async throws -> (message: AgentTranscriptMessage, reason: AgentStopReason) {
        var message = AgentTranscriptMessage(role: .assistant)
        var pending: [String: PendingToolCall] = [:]
        var order: [String] = []
        var stopReason = AgentStopReason.completed
        emit(.messageStarted(message.id))

        let request = AgentModelRequest(
            systemPrompt: systemPrompt,
            messages: messages,
            tools: tools.values.map(\.descriptor).sorted { $0.name < $1.name }
        )
        for try await event in model.stream(request) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let text):
                message.text += text
                emit(.messageDelta(messageID: message.id, text: text))
            case .textSnapshot(let text):
                // The UI is reconciled by messageFinished after the provider
                // stream closes, so replacing here cannot duplicate deltas.
                message.text = text
            case .toolCallDelta(let id, let name, let arguments):
                if pending[id] == nil { order.append(id) }
                var entry = pending[id] ?? PendingToolCall()
                if let name { entry.name = name }
                entry.arguments += arguments
                pending[id] = entry
            case .toolCallSnapshot(let id, let providerItemID, let name, let arguments):
                if pending[id] == nil { order.append(id) }
                pending[id] = PendingToolCall(
                    name: name, arguments: arguments,
                    providerItemID: providerItemID
                )
            case .providerItem(let item):
                if let id = item.objectValue?["id"]?.stringValue,
                    let index = message.providerItems.firstIndex(where: {
                        $0.objectValue?["id"]?.stringValue == id
                    })
                {
                    // `response.completed` can carry a richer final reasoning
                    // item (notably encrypted_content) than output_item.done.
                    message.providerItems[index] = item
                } else {
                    message.providerItems.append(item)
                }
            case .finished(let reason):
                stopReason = reason
            }
        }
        message.toolCalls = try order.map { id in
            guard let call = pending[id], !call.name.isEmpty else {
                throw AgentRuntimeError.invalidToolCall
            }
            // A zero-parameter tool has exactly one valid argument value. Do
            // not let an OpenAI-compatible gateway's empty/null/duplicated
            // serialization turn `list_hosts` into a JSON decoding failure.
            if let schema = tools[call.name]?.descriptor.inputSchema.objectValue,
                schema["properties"]?.objectValue?.isEmpty == true,
                schema["additionalProperties"]?.boolValue == false
            {
                return AgentToolCall(
                    id: id, name: call.name, arguments: .object([:]),
                    providerItemID: call.providerItemID
                )
            }
            // Several OpenAI-compatible gateways stream an empty argument
            // string for a no-parameter function instead of the canonical `{}`.
            let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = (arguments.isEmpty ? "{}" : arguments).data(using: .utf8) else {
                throw AgentRuntimeError.invalidToolCall
            }
            do {
                return AgentToolCall(
                    id: id, name: call.name,
                    arguments: try AgentJSONValue.decode(data),
                    providerItemID: call.providerItemID
                )
            } catch {
                throw AgentRuntimeError.invalidToolArguments(tool: call.name)
            }
        }
        return (message, stopReason)
    }

    private func execute(
        _ call: AgentToolCall,
        runID: UUID,
        mode: ChatPermissionMode,
        userIntent: String
    ) async -> AgentToolResult {
        guard let tool = tools[call.name] else {
            // Still a card. Returning silently left the transcript showing an
            // empty assistant turn and nothing else, which reads as "the model
            // said nothing" rather than "the model called a tool we do not
            // have" — the one thing the user needs to see here.
            let invocation = AgentToolInvocation(runID: runID, call: call)
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Unknown tool: \(call.name)"),
                isError: true
            )
            emit(.toolProposed(invocation, AgentToolDescriptor(
                name: call.name,
                summary: String(localized: "This tool is not available in this run."),
                inputSchema: .object(["type": .string("object")]),
                target: .local, safety: .requiresAuthorization
            )))
            emit(.toolFinished(invocation, result))
            return result
        }
        let proposed = AgentToolInvocation(runID: runID, call: call)
        let preflight: AgentToolPreflight
        do {
            try AgentJSONSchemaValidator.validate(call.arguments, against: tool.descriptor.inputSchema)
            preflight = try await tool.preflight(proposed)
        } catch {
            let result = AgentToolResult(
                callID: call.id,
                content: String(localized: "Tool input was rejected: \(error.localizedDescription)"),
                isError: true
            )
            emit(.toolProposed(proposed, tool.descriptor))
            emit(.toolFinished(proposed, result))
            return result
        }
        let invocation = preflight.invocation
        var effectiveDescriptor = tool.descriptor
        effectiveDescriptor.safety = preflight.safety
        emit(.toolProposed(invocation, effectiveDescriptor))
        let request = AgentApprovalRequest(
            invocation: invocation,
            descriptor: effectiveDescriptor,
            userIntent: userIntent,
            localReasons: preflight.reasons
        )
        switch await approval.authorize(request, mode: mode) {
        case .deny(let reason):
            let result = AgentToolResult(callID: call.id, content: reason, isError: true)
            emit(.toolFinished(invocation, result))
            return result
        case .allow:
            emit(.toolStarted(invocation))
            do {
                let result = try await tool.execute(
                    invocation,
                    context: AgentToolExecutionContext(
                        runID: runID, userIntent: userIntent, secretBroker: secretBroker,
                        userInteraction: EventingAgentUserInteraction(
                            base: userInteraction,
                            event: { [weak self] event in await self?.emit(event) }
                        ),
                        preflightMetadata: preflight.executionMetadata,
                        authorize: { [approval] request in
                            await approval.authorize(request, mode: mode)
                        }
                    )
                )
                emit(.toolFinished(invocation, result))
                return result
            } catch {
                let result = AgentToolResult(
                    callID: call.id, content: error.localizedDescription, isError: true
                )
                emit(.toolFinished(invocation, result))
                return result
            }
        }
    }

    private func persist(_ snapshot: AgentRunSnapshot) async {
        try? await repository.save(snapshot)
    }

    private func finish(runID: UUID) {
        // Secrets, and nothing else. SSH and SFTP connections used to be closed
        // here too; they are now pooled per host and given back by an idle
        // sweep, so a run ending is no longer the event that releases them.
        Task { await secretBroker.discardSecrets(for: runID) }
        activeRunID = nil
        runTask = nil
        continuation?.finish()
        continuation = nil
    }
}

nonisolated enum AgentRuntimeError: LocalizedError, Sendable {
    case invalidToolCall, invalidToolArguments(tool: String), truncatedToolCall
    case toolBudgetExceeded, turnBudgetExceeded, providerFailed

    var errorDescription: String? {
        switch self {
        case .invalidToolCall: String(localized: "The model returned an invalid tool call.")
        case .invalidToolArguments(let tool):
            String(localized: "The model returned malformed JSON arguments for \(tool).")
        case .truncatedToolCall: String(localized: "A truncated model response contained tool calls; none were executed.")
        case .toolBudgetExceeded: String(localized: "The agent reached its tool-call limit.")
        case .turnBudgetExceeded: String(localized: "The agent reached its turn limit.")
        case .providerFailed: String(localized: "The model provider failed to complete the response.")
        }
    }
}

import Foundation

nonisolated struct AgentModelRequest: Sendable {
    var systemPrompt: String
    var messages: [AgentTranscriptMessage]
    var tools: [AgentToolDescriptor]
}

nonisolated enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    case toolCallDelta(id: String, name: String?, arguments: String)
    case finished(AgentStopReason)
}

nonisolated protocol AgentModelStreaming: Sendable {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error>
}

nonisolated struct AgentToolExecutionContext: Sendable {
    var runID: UUID
    var userIntent: String
    var secretBroker: SecretBroker
    var userInteraction: any AgentUserInteractionHandling
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
}

nonisolated extension AgentRunPersisting {
    func record(_ event: AgentEvent, runID: UUID) async throws {}
    func loadConversations() async throws -> [StoredAgentConversation] { [] }
}

nonisolated struct StoredAgentConversation: Sendable {
    var id: UUID
    var messages: [AgentTranscriptMessage]
    var toolCards: [StoredAgentToolCard] = []
    var lastRunState: AgentRunState
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
    private var deletedConversationIDs = Set<UUID>()
    func save(_ snapshot: AgentRunSnapshot) {
        guard !deletedConversationIDs.contains(snapshot.conversationID) else { return }
        snapshots[snapshot.id] = snapshot
    }
    func snapshot(_ id: UUID) -> AgentRunSnapshot? { snapshots[id] }
    func deleteConversation(_ id: UUID) {
        deletedConversationIDs.insert(id)
        snapshots = snapshots.filter { $0.value.conversationID != id }
    }
}

/// Low-level Pi-style loop: stream one assistant turn, collect complete tool calls,
/// authorize and execute them in source order, append results, then ask the model again.
actor AgentRuntime {
    private struct PendingToolCall {
        var name = ""
        var arguments = ""
    }

    private let model: any AgentModelStreaming
    private let approval: any AgentApprovalHandling
    private let repository: any AgentRunPersisting
    private let userInteraction: any AgentUserInteractionHandling
    private let runCleanup: @Sendable (UUID) async -> Void
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
        runCleanup: @escaping @Sendable (UUID) async -> Void = { _ in },
        maxTurns: Int = 24,
        maxToolCalls: Int = 64
    ) {
        self.model = model
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.descriptor.name, $0) })
        self.approval = approval
        self.repository = repository
        self.secretBroker = secretBroker
        self.userInteraction = userInteraction
        self.runCleanup = runCleanup
        self.maxTurns = maxTurns
        self.maxToolCalls = maxToolCalls
    }

    func start(_ request: AgentRunRequest) -> AsyncStream<AgentEvent> {
        cancel()
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
        if let runID = activeRunID {
            Task { try? await repository.record(event, runID: runID) }
        }
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
                    messages: snapshot.messages
                )
                snapshot.messages.append(turn.message)
                emit(.messageFinished(turn.message))
                await persist(snapshot)

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
            case .toolCallDelta(let id, let name, let arguments):
                if pending[id] == nil { order.append(id) }
                var entry = pending[id] ?? PendingToolCall()
                if let name { entry.name = name }
                entry.arguments += arguments
                pending[id] = entry
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
                    id: id, name: call.name, arguments: .object([:])
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
                    arguments: try AgentJSONValue.decode(data)
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
            return AgentToolResult(
                callID: call.id,
                content: String(localized: "Unknown tool: \(call.name)"),
                isError: true
            )
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
                        )
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
        Task {
            await secretBroker.discardSecrets(for: runID)
            await runCleanup(runID)
        }
        activeRunID = nil
        runTask = nil
        continuation?.finish()
        continuation = nil
    }
}

nonisolated enum AgentRuntimeError: LocalizedError, Sendable {
    case invalidToolCall, invalidToolArguments(tool: String), truncatedToolCall
    case toolBudgetExceeded, turnBudgetExceeded

    var errorDescription: String? {
        switch self {
        case .invalidToolCall: String(localized: "The model returned an invalid tool call.")
        case .invalidToolArguments(let tool):
            String(localized: "The model returned malformed JSON arguments for \(tool).")
        case .truncatedToolCall: String(localized: "A truncated model response contained tool calls; none were executed.")
        case .toolBudgetExceeded: String(localized: "The agent reached its tool-call limit.")
        case .turnBudgetExceeded: String(localized: "The agent reached its turn limit.")
        }
    }
}

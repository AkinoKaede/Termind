import Foundation

/// Everything about a run that is a policy rather than a dependency.
///
/// Held as one value so a caller can change how a run behaves without a
/// twelve-argument initializer, and so the defaults live in one readable place.
nonisolated struct AgentLoopConfiguration: Sendable {
    var maxTurns = 24
    var maxToolCalls = 64
    /// The run-wide default. Individual tools may still force their batch
    /// serial; none can force it parallel. See `AgentToolScheduler`.
    var toolExecution: AgentToolExecutionMode = .parallel
    var maximumToolConcurrency = 8
    /// The `transformContext` seam, replaceable whole. Given the run's session
    /// context block, the id of the turn it belongs in front of, and whether the
    /// run is planning, it returns the chain applied to every request this run
    /// makes.
    var contextPipeline:
        @Sendable (AgentTranscriptMessage?, AgentTranscriptMessage.ID?, Bool)
            -> AgentContextPipeline = AgentContextPipeline.chat

    init() {}
}

/// The agent's state and its loop.
///
/// State: the transcript snapshot, the tool registry, the steering queue, the
/// secret broker, and the task a run is executing on. Loop: stream one
/// assistant turn, schedule the tools it asked for, feed the results back, ask
/// again.
///
/// The phases themselves live elsewhere — `AgentTurnDriver`,
/// `AgentToolScheduler`, `AgentToolExecutor`, `AgentContextPipeline` — so that
/// each is testable without a run around it, and so this file stays short
/// enough to read as a description of the loop.
actor AgentRuntime {
    private let model: any AgentModelStreaming
    private let approval: any AgentApprovalHandling
    private let repository: any AgentRunPersisting
    private let userInteraction: any AgentUserInteractionHandling
    let secretBroker: SecretBroker
    private let tools: AgentToolRegistry
    private let hooks: AgentLoopHooks
    private let configuration: AgentLoopConfiguration
    private let channel: AgentEventChannel
    private var runTask: Task<Void, Never>?
    private var steering: [AgentTranscriptMessage] = []
    /// Armed while something the user typed is waiting for a boundary, so a
    /// tool that is only waiting can stop waiting. Offered to tools rather than
    /// imposed on them — see `AgentInterjectionSignal`.
    private let interjection = AgentInterjectionSignal()
    /// Whether a message queued *now* would still be delivered.
    ///
    /// Not the same question as "is there a run task". `complete` awaits its
    /// final persist before it ends the run, and an actor is reentrant at every
    /// await — so a message accepted during that window would land in a queue
    /// nobody drains again. Cleared as the *first* statement of every path that
    /// ends a run, which is what makes the window empty rather than narrow.
    private var acceptsSteering = false
    private var activeRunID: UUID?

    init(
        model: any AgentModelStreaming,
        tools: [AnyAgentTool],
        approval: any AgentApprovalHandling,
        repository: any AgentRunPersisting = InMemoryAgentRunRepository(),
        secretBroker: SecretBroker = SecretBroker(),
        userInteraction: any AgentUserInteractionHandling = UnavailableAgentUserInteraction(),
        hooks: [any AgentLoopHook] = [],
        configuration: AgentLoopConfiguration = AgentLoopConfiguration(),
        channel: AgentEventChannel? = nil
    ) {
        self.init(
            model: model, registry: AgentToolRegistry(tools), approval: approval,
            repository: repository, secretBroker: secretBroker,
            userInteraction: userInteraction, hooks: hooks,
            configuration: configuration, channel: channel
        )
    }

    init(
        model: any AgentModelStreaming,
        registry: AgentToolRegistry,
        approval: any AgentApprovalHandling,
        repository: any AgentRunPersisting = InMemoryAgentRunRepository(),
        secretBroker: SecretBroker = SecretBroker(),
        userInteraction: any AgentUserInteractionHandling = UnavailableAgentUserInteraction(),
        hooks: [any AgentLoopHook] = [],
        configuration: AgentLoopConfiguration = AgentLoopConfiguration(),
        channel: AgentEventChannel? = nil
    ) {
        self.model = model
        self.tools = registry
        self.approval = approval
        self.repository = repository
        self.secretBroker = secretBroker
        self.userInteraction = userInteraction
        self.hooks = AgentLoopHooks(hooks)
        self.configuration = configuration
        // A caller that also has to publish events — `AgentApprovalBroker` does
        // — passes the channel in so both writers share one ordered path. On
        // its own, a runtime makes the channel it needs.
        self.channel = channel ?? AgentEventChannel(repository: repository)
    }

    /// Begins a run and hands back the events it will produce.
    ///
    /// One runtime serves one run: the returned sequence is the channel's, and
    /// an `AsyncStream` has a single consumer.
    func start(_ request: AgentRunRequest) -> AsyncStream<AgentEvent> {
        cancel()
        // Before the task exists, not inside it. A message queued in the gap
        // would otherwise be refused for want of a run that is already on its
        // way, and the first drain happens ahead of the first provider request
        // — so even something typed this early is delivered rather than lost.
        acceptsSteering = true
        runTask = Task { [weak self] in
            await self?.run(request)
        }
        return channel.events
    }

    /// Queues a message for the next model boundary.
    ///
    /// `false` means there is no run left to steer and the caller still owns
    /// the text — it must put it somewhere the user can see, because nothing
    /// here will ever send it.
    @discardableResult
    func steer(_ message: AgentTranscriptMessage) -> Bool {
        guard acceptsSteering else { return false }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        steering.append(message)
        interjection.arm()
        return true
    }

    func cancel() {
        acceptsSteering = false
        runTask?.cancel()
        runTask = nil
        if let runID = activeRunID { Task { await secretBroker.discardSecrets(for: runID) } }
    }

    private func run(_ request: AgentRunRequest) async {
        var snapshot = AgentRunSnapshot(
            conversationID: request.conversationID,
            state: .running,
            permissionMode: request.permissionMode,
            // Applied to incoming history as well as at the model boundary,
            // which is what makes these repairs and not just guards: this
            // snapshot is persisted, so a call left unanswered by a process
            // that died — or a result left behind by one — is fixed once here
            // rather than re-derived on every future turn of the conversation.
            messages: AgentOrphanedToolResultRepair.apply(
                AgentUnansweredToolCallRepair.apply(request.priorMessages)
            )
        )
        activeRunID = snapshot.id
        let runID = snapshot.id
        let sessionContext = request.sessionContext.modelContext.map {
            AgentTranscriptMessage(role: .user, text: $0)
        }
        let prompt = AgentTranscriptMessage(
            role: .user, text: request.prompt, images: request.promptImages
        )
        snapshot.messages.append(prompt)
        let pipeline = configuration.contextPipeline(
            sessionContext, prompt.id, request.isPlanning
        )

        channel.emit(.runStarted(runID))
        channel.emit(.runState(.running))
        await persist(snapshot)

        let driver = AgentTurnDriver(
            model: model, tools: tools, channel: channel, runID: runID
        )
        let scheduler = AgentToolScheduler(
            executor: AgentToolExecutor(
                tools: tools, approval: approval, hooks: hooks, channel: channel,
                secretBroker: secretBroker, userInteraction: userInteraction,
                runID: runID, permissionMode: request.permissionMode,
                userIntent: request.prompt,
                interjection: { [interjection] in await interjection.wait() }
            ),
            mode: configuration.toolExecution,
            maximumConcurrency: configuration.maximumToolConcurrency
        )

        var toolCount = 0
        do {
            for index in 0..<configuration.maxTurns {
                try Task.checkCancellation()
                channel.emit(.turnStarted(index: index))
                if !steering.isEmpty {
                    snapshot.messages.append(contentsOf: deliverSteering())
                    await persist(snapshot)
                }
                let turn = try await driver.run(pipeline(AgentModelContext(
                    systemPrompt: request.systemPrompt,
                    messages: snapshot.messages,
                    tools: tools.descriptors
                )))
                snapshot.messages.append(turn.message)
                channel.emit(.messageFinished(turn.message))
                // Replaced, not accumulated across turns: this turn's input
                // already counts everything the earlier turns put in the
                // context, so summing them would count the same conversation
                // once per turn it survived.
                if !turn.usage.isEmpty { channel.emit(.usageUpdated(turn.usage)) }
                channel.emit(.turnFinished(index: index, stopReason: turn.reason))
                await persist(snapshot)

                if turn.reason == .error { throw AgentRuntimeError.providerFailed }
                guard !turn.message.toolCalls.isEmpty else {
                    // A reply with nothing to run used to end the run right
                    // here, which threw away whatever the user had typed while
                    // it was being written — on screen as a turn the model was
                    // never shown. Pi keeps its inner loop alive while messages
                    // are pending for exactly this reason; the next iteration
                    // delivers them and asks again.
                    if steering.isEmpty { return await complete(snapshot, runID: runID) }
                    continue
                }

                // Refusals still produce one result per call, then throw. An
                // assistant turn whose tool calls are left unanswered is
                // rejected outright by every provider on the *next* request, so
                // giving up here without answering would turn a stopped run
                // into a permanently unusable conversation.
                var refusal: AgentRuntimeError?
                let results: [AgentToolResult]
                if turn.reason == .length {
                    refusal = .truncatedToolCall
                    results = scheduler.fail(
                        turn.message.toolCalls,
                        reason: AgentRuntimeError.truncatedToolCall.localizedDescription
                    )
                } else if toolCount + turn.message.toolCalls.count > configuration.maxToolCalls {
                    refusal = .toolBudgetExceeded
                    results = scheduler.fail(
                        turn.message.toolCalls,
                        reason: AgentRuntimeError.toolBudgetExceeded.localizedDescription
                    )
                } else {
                    toolCount += turn.message.toolCalls.count
                    results = await scheduler.run(turn.message.toolCalls)
                }
                for (call, result) in zip(turn.message.toolCalls, results) {
                    snapshot.messages.append(AgentTranscriptMessage(
                        role: .tool, text: result.content, toolCallID: result.callID,
                        toolName: call.name, isError: result.isError
                    ))
                }
                await persist(snapshot)
                if let refusal { throw refusal }
                // After the results are recorded, not before: a cancelled batch
                // still leaves the transcript answerable.
                try Task.checkCancellation()

                if await hooks.shouldStop(after: AgentTurnSummary(
                    index: index, message: turn.message, results: results
                )) {
                    return await complete(snapshot, runID: runID)
                }
            }
            throw AgentRuntimeError.turnBudgetExceeded
        } catch is CancellationError {
            acceptsSteering = false
            snapshot.state = .cancelled
            snapshot.finishedAt = .now
            channel.emit(.runState(.cancelled))
            await persist(snapshot)
        } catch {
            acceptsSteering = false
            snapshot.state = .failed
            snapshot.failure = error.localizedDescription
            snapshot.finishedAt = .now
            channel.emit(.failed(error.localizedDescription))
            channel.emit(.runState(.failed))
            await persist(snapshot)
        }
        finish(runID: runID)
    }

    /// Empties the queue into the turn that is about to start, and says so.
    ///
    /// The timestamp is rewritten here rather than kept from the keystroke that
    /// queued it. A conversation orders assistant turns and tool cards by time,
    /// and a message stamped while the previous turn was still streaming sorts
    /// above the reply the user was reading when they typed it — which is not
    /// where the model saw it.
    private func deliverSteering() -> [AgentTranscriptMessage] {
        let delivered = steering.map { queued in
            var message = queued
            message.createdAt = .now
            return message
        }
        steering.removeAll()
        interjection.disarm()
        for message in delivered { channel.emit(.steeringDelivered(message)) }
        return delivered
    }

    private func complete(_ snapshot: AgentRunSnapshot, runID: UUID) async {
        acceptsSteering = false
        var finished = snapshot
        finished.state = .completed
        finished.finishedAt = .now
        channel.emit(.runState(.completed))
        await persist(finished)
        finish(runID: runID)
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
        channel.finish()
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

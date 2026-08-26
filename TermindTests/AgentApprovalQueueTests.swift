import Foundation
import Testing

@testable import Termind

private actor CallLog {
    private(set) var started: [String] = []
    private(set) var finished: [String] = []
    func start(_ name: String) { started.append(name) }
    func finish(_ name: String) { finished.append(name) }
}

private actor QueueScriptedModel: AgentModelStreaming {
    private let turns: [[AgentModelStreamEvent]]
    private var index = 0

    init(_ turns: [[AgentModelStreamEvent]]) { self.turns = turns }

    private func next() -> [AgentModelStreamEvent] {
        defer { index += 1 }
        return turns[min(index, turns.count - 1)]
    }

    nonisolated func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                for event in await next() { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

private let queueSchema = AgentJSONValue.object([
    "type": .string("object"), "properties": .object([:]),
    "required": .array([]), "additionalProperties": .bool(false),
])

private func turnsCalling(_ names: [String]) -> [[AgentModelStreamEvent]] {
    [
        names.enumerated().map { index, name in
            .toolCallSnapshot(
                id: "call-\(index)", providerItemID: nil, name: name, arguments: "{}"
            )
        } + [.finished(.toolCalls)],
        [.textDelta("done"), .finished(.completed)],
    ]
}

/// Requires authorization and may run beside its peers — the combination the
/// single pending-approval slot could not survive.
private func gatedTool(_ name: String, log: CallLog) -> AnyAgentTool {
    AnyAgentTool(descriptor: AgentToolDescriptor(
        name: name, summary: name, inputSchema: queueSchema,
        target: .host, safety: .requiresAuthorization, concurrency: .parallel
    )) { invocation, _ in
        await log.start(name)
        await log.finish(name)
        return AgentToolResult(callID: invocation.call.id, content: name)
    }
}

/// Never returns on its own; only cancellation ends it.
private func hangingTool(_ name: String, log: CallLog) -> AnyAgentTool {
    AnyAgentTool(descriptor: AgentToolDescriptor(
        name: name, summary: name, inputSchema: queueSchema,
        target: .local, safety: .locallyReadOnly, concurrency: .parallel
    )) { invocation, _ in
        await log.start(name)
        try await Task.sleep(for: .seconds(30))
        return AgentToolResult(callID: invocation.call.id, content: name)
    }
}

@Suite
struct AgentApprovalQueueTests {
    /// The bug this replaces was a deadlock, not a cosmetic one: two calls
    /// needing approval in the same turn overwrote the single pending slot, and
    /// the first request's continuation was never resumed. The run stopped with
    /// nothing on screen to answer and no error to report.
    @MainActor
    @Test
    func twoApprovalsInOneTurnQueueAndAreBothAnswered() async {
        let log = CallLog()
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: QueueScriptedModel(turnsCalling(["first", "second"])),
            tools: [gatedTool("first", log: log), gatedTool("second", log: log)],
            approval: AgentApprovalBroker(
                reviewer: nil,
                manualApproval: { [weak conversation] request in
                    guard let conversation else { return .deny("gone") }
                    return await conversation.requestApproval(request)
                }
            )
        )

        conversation.start(runtime: runtime, request: AgentRunRequest(
            conversationID: conversation.id, prompt: "go", permissionMode: .askForApproval
        ))

        await wait { conversation.pendingApprovals.count == 2 }
        // Both are waiting, but only the head is presented: authorizing three
        // things while reading one is not a decision anybody made.
        #expect(conversation.pendingApproval?.id == conversation.pendingApprovals.first?.id)
        #expect(conversation.runState == .waitingForApproval)

        conversation.respondToApproval(allow: true)
        await wait { conversation.pendingApprovals.count == 1 }
        conversation.respondToApproval(allow: true)
        await waitForTerminal(conversation)

        #expect(await log.finished.sorted() == ["first", "second"])
        #expect(conversation.runState == .completed)
        #expect(conversation.pendingApprovals.isEmpty)
    }

    @MainActor
    @Test
    func denyingTheHeadLeavesTheNextRequestAnswerable() async {
        let log = CallLog()
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: QueueScriptedModel(turnsCalling(["denied", "allowed"])),
            tools: [gatedTool("denied", log: log), gatedTool("allowed", log: log)],
            approval: AgentApprovalBroker(
                reviewer: nil,
                manualApproval: { [weak conversation] request in
                    guard let conversation else { return .deny("gone") }
                    return await conversation.requestApproval(request)
                }
            )
        )

        conversation.start(runtime: runtime, request: AgentRunRequest(
            conversationID: conversation.id, prompt: "go", permissionMode: .askForApproval
        ))

        await wait { conversation.pendingApprovals.count == 2 }
        conversation.respondToApproval(allow: false)
        await wait { conversation.pendingApprovals.count == 1 }
        conversation.respondToApproval(allow: true)
        await waitForTerminal(conversation)

        #expect(await log.finished == ["allowed"])
        #expect(conversation.toolCards.contains { $0.state == .denied })
        // Both calls are still answered, one with the denial, so the turn stays
        // replayable.
        #expect(conversation.transcript.filter { $0.role == .tool }.count == 2)
    }

    /// Run state is derived from what is outstanding rather than asserted by
    /// whichever tool moved last, so one answered question cannot unlock the
    /// composer over another that is still open.
    @MainActor
    @Test
    func runStateFollowsTheDeepestOutstandingWait() async {
        let conversation = ConversationModel()
        conversation.handle(.runState(.running))
        #expect(conversation.runState == .running)

        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "1", name: "review", arguments: .object([:]))
        )
        let request = AgentApprovalRequest(
            invocation: invocation,
            descriptor: AgentToolDescriptor(
                name: "review", summary: "review", inputSchema: queueSchema,
                target: .host, safety: .requiresAuthorization
            ),
            userIntent: "go"
        )
        conversation.handle(.reviewStarted(request))
        #expect(conversation.runState == .reviewing)

        conversation.present(
            AgentUserInputRequest(
                questions: [AgentUserQuestion(id: "host", prompt: "which host?", kind: .text)]
            )
        )
        #expect(conversation.runState == .waitingForUser)

        // The review finishing must not announce that nothing is outstanding.
        conversation.handle(.reviewFinished(request, SecurityReviewDecision(
            verdict: .approve, risk: .low, userAuthorization: .sufficient, reason: "ok"
        )))
        #expect(conversation.runState == .waitingForUser)

        conversation.cancelUserInput()
        #expect(conversation.runState == .running)
    }

    /// Cancelling mid-batch must still answer every call. An assistant turn
    /// with unanswered tool calls is rejected by every provider on the *next*
    /// request, so a stopped run would otherwise become an unusable
    /// conversation rather than an interrupted one.
    @Test
    func cancellingAParallelBatchStillAnswersEveryCall() async {
        let log = CallLog()
        let runtime = AgentRuntime(
            model: QueueScriptedModel(turnsCalling(["a", "b"])),
            tools: [hangingTool("a", log: log), hangingTool("b", log: log)],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        let stream = await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
        ))
        let collector = Task {
            var events: [AgentEvent] = []
            for await event in stream { events.append(event) }
            return events
        }

        for _ in 0..<400 where await log.started.count < 2 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        await runtime.cancel()
        let events = await collector.value

        let finished = events.filter { if case .toolFinished = $0 { true } else { false } }
        #expect(finished.count == 2, "every call in the batch needs a result")
        #expect(events.contains(.runState(.cancelled)))
    }

    @MainActor
    private func wait(for condition: @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private func waitForTerminal(_ conversation: ConversationModel) async {
        await wait { conversation.runState.isTerminal }
    }
}

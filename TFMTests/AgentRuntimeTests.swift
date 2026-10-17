import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import Termind

private struct ScriptedAgentModel: AgentModelStreaming {
    let turns: [[AgentModelStreamEvent]]
    let counter = Counter()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await counter.next()
                for event in turns[min(index, turns.count - 1)] { continuation.yield(event) }
                continuation.finish()
            }
        }
    }

    actor Counter {
        var value = 0
        func next() -> Int {
            defer { value += 1 }
            return value
        }
    }
}

private struct FixedReviewer: GuardianReviewing {
    var result: Result<GuardianDecision, any Error>
    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision { try result.get() }
}

private actor CountingReviewer: GuardianReviewing {
    private(set) var count = 0
    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        count += 1
        return GuardianDecision(
            verdict: .approve, risk: .medium,
            userAuthorization: .high, reason: "approved"
        )
    }
}

private struct ReviewFailure: Error {}

private struct HangingReviewer: GuardianReviewing {
    func review(_ request: AgentApprovalRequest) async throws -> GuardianDecision {
        try await Task.sleep(for: .seconds(30))
        return GuardianDecision(
            verdict: .approve, risk: .low,
            userAuthorization: .high, reason: "late"
        )
    }
}

private struct CapturingAgentModel: AgentModelStreaming {
    let requests: RequestRecorder
    let counter = ScriptedAgentModel.Counter()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(request)
                if await counter.next() == 0 {
                    continuation.yield(
                        .providerItem(
                            .object([
                                "type": .string("reasoning"), "id": .string("reasoning-1"),
                            ])))
                    continuation.yield(
                        .providerItem(
                            .object([
                                "type": .string("reasoning"), "id": .string("reasoning-1"),
                                "encrypted_content": .string("final-state"),
                            ])))
                    continuation.yield(.toolCallDelta(id: "wait", name: "wait", arguments: "{}"))
                    continuation.yield(.finished(.toolCalls))
                } else {
                    continuation.yield(.textDelta("done"))
                    continuation.yield(.finished(.completed))
                }
                continuation.finish()
            }
        }
    }
}

/// Holds its first response open until released, and never asks for a tool.
///
/// The gate has to be inside the *model* rather than inside a tool for this to
/// mean anything: the case under test is a turn that ends the run all by
/// itself, which is precisely the turn with no tool to hold open.
private struct GatedAgentModel: AgentModelStreaming {
    let requests: RequestRecorder
    let gate: AsyncGate
    let counter = ScriptedAgentModel.Counter()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(request)
                if await counter.next() == 0 {
                    continuation.yield(.textDelta("looking into it"))
                    await gate.beginAndWait()
                } else {
                    continuation.yield(.textDelta("done"))
                }
                continuation.yield(.finished(.completed))
                continuation.finish()
            }
        }
    }
}

private struct RecordingScriptedAgentModel: AgentModelStreaming {
    let turns: [[AgentModelStreamEvent]]
    let requests: RequestRecorder
    let counter = ScriptedAgentModel.Counter()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(request)
                let index = await counter.next()
                for event in turns[min(index, turns.count - 1)] { continuation.yield(event) }
                continuation.finish()
            }
        }
    }
}

@Suite
struct AgentRuntimeTests {
    @Test
    func restoredSecretHandlesAreRemovedBeforeTheNextModelRequest() async throws {
        let requests = RequestRecorder()
        let repository = InMemoryAgentRunRepository()
        let model = RecordingScriptedAgentModel(
            turns: [[.textDelta("done"), .finished(.completed)]],
            requests: requests
        )
        let runtime = AgentRuntime(
            model: model, tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        let requestSecret = AgentToolCall(
            id: "secret", name: "request_user_secret", arguments: .object([:])
        )
        let legacyExec = AgentToolCall(
            id: "exec", name: "ssh_exec",
            arguments: .object([
                "host_id": .string(UUID().uuidString),
                "command": .string("uptime"),
                "secret_handle": .string("[REDACTED]"),
            ])
        )
        let prior = [
            AgentTranscriptMessage(role: .assistant, toolCalls: [requestSecret]),
            AgentTranscriptMessage(
                role: .tool,
                text: "<untrusted-data>\n{\"secret_handle\":\"OLD-HANDLE\"}\n</untrusted-data>",
                toolCallID: requestSecret.id, toolName: requestSecret.name
            ),
            AgentTranscriptMessage(role: .assistant, toolCalls: [legacyExec]),
            AgentTranscriptMessage(
                role: .tool, text: "finished", toolCallID: legacyExec.id,
                toolName: legacyExec.name
            ),
        ]
        var runID: UUID?

        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "again",
                permissionMode: .askForApproval, priorMessages: prior
            ))
        {
            runID = runID ?? event.associatedRunID
        }

        let sent = try #require(await requests.values.first)
        let sentExec = try #require(
            sent.messages.flatMap(\.toolCalls).first { $0.name == "ssh_exec" }
        )
        #expect(sentExec.arguments.objectValue?["secret_handle"] == nil)
        #expect(!sent.messages.map(\.text).joined().contains("OLD-HANDLE"))
        #expect(sent.messages.map(\.text).joined().contains("expired"))

        let completedRunID = try #require(runID)
        let saved = try #require(await repository.snapshot(completedRunID))
        let savedExec = try #require(
            saved.messages.flatMap(\.toolCalls).first { $0.name == "ssh_exec" }
        )
        #expect(savedExec.arguments.objectValue?["secret_handle"] == nil)
    }

    /// The system prompt is the cached prefix of every request, and a terminal's
    /// working directory is the most volatile value the app has. Putting one
    /// inside the other meant a single `cd` between turns changed byte zero and
    /// missed the whole replayed conversation.
    @Test
    func sessionContextRidesTheMessageTailAndLeavesTheSystemPromptAlone() async {
        let requests = RequestRecorder()
        let repository = InMemoryAgentRunRepository()
        let model = RecordingScriptedAgentModel(
            turns: [
                [
                    .toolCallSnapshot(
                        id: "inspect", providerItemID: nil, name: "inspect",
                        arguments: "{}"
                    ),
                    .finished(.toolCalls),
                ],
                [.textDelta("done"), .finished(.completed)],
            ],
            requests: requests
        )
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "inspect", summary: "inspect",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: "ok")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        let context = SessionContext(
            hostName: "edge-01",
            workingDirectory: "/srv/app",
            systemInfo: RemoteSystemInfo(
                distributionID: "alpine", distributionVersion: "3.20.2",
                kernelName: "Linux", kernelRelease: "6.6.44-0-lts",
                architecture: "aarch64"
            )
        )
        var runID: UUID?

        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "inspect", permissionMode: .askForApproval,
                sessionContext: context.modelContext
            ))
        {
            runID = runID ?? event.associatedRunID
        }

        let captured = await requests.values
        #expect(captured.count == 2)
        // Byte-identical to the default across every run, which is the whole
        // point: nothing session-specific may reach the cached prefix.
        #expect(captured.allSatisfy { $0.systemPrompt == AgentSystemPrompt.default })

        // One block, carrying everything, sitting between the replayed history
        // and the turn it describes.
        #expect(
            captured.allSatisfy { request in
                request.messages.filter { $0.text.contains("cwd: /srv/app") }.count == 1
            })
        #expect(
            captured.allSatisfy { request in
                guard
                    let index = request.messages.firstIndex(where: {
                        $0.text.contains("Session context")
                    })
                else { return false }
                let block = request.messages[index].text
                return block.contains("host_name: edge-01")
                    && block.contains("distribution_id: alpine")
                    && block.contains("kernel_release: 6.6.44-0-lts")
                    && block.contains("architecture: aarch64")
                    && request.messages[index...].contains { $0.text == "inspect" }
            })

        // The snapshot is durable metadata; the visible user text stays authored.
        let id = try! #require(runID)
        let saved = try! #require(await repository.snapshot(id)).messages
        #expect(saved.contains { $0.text == "inspect" })
        #expect(!saved.contains { $0.text.contains("Session context") })
        #expect(saved.first { $0.text == "inspect" }?.contextSnapshot?.sessionContext == context.modelContext)
    }

    @Test
    func toolsExecuteInSourceOrderAndResultsReturnToTheModel() async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(id: "1", name: "first", arguments: "{\"value\":"),
                .toolCallDelta(id: "1", name: nil, arguments: "1}"),
                .toolCallDelta(id: "2", name: "second", arguments: "{}"),
                .finished(.toolCalls),
            ],
            [.textDelta("done"), .finished(.completed)],
        ])
        let recorder = Recorder()
        let tools = ["first", "second"].map { name in
            AnyAgentTool(
                descriptor: AgentToolDescriptor(
                    name: name, summary: name,
                    inputSchema: .object(["type": .string("object")]),
                    target: .local, approvalPolicy: .approve
                )
            ) { invocation, _ in
                await recorder.append(name)
                return AgentToolResult(callID: invocation.call.id, content: name)
            }
        }
        let broker = AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .deny("unexpected") })
        let runtime = AgentRuntime(model: model, tools: tools, approval: broker)
        var events: [AgentEvent] = []
        for await event in await runtime.start(
            AgentRunRequest(conversationID: UUID(), prompt: "go", permissionMode: .askForApproval)
        ) { events.append(event) }

        #expect(await recorder.values == ["first", "second"])
        #expect(events.contains(.runState(.completed)))
    }

    @Test
    func steeringJoinsTheTranscriptAtTheNextModelBoundary() async {
        let requests = RequestRecorder()
        let gate = AsyncGate()
        let events = EventRecorder()
        let model = CapturingAgentModel(requests: requests)
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "wait", summary: "wait",
                inputSchema: .object(["type": .string("object")]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            await gate.beginAndWait()
            return AgentToolResult(callID: invocation.call.id, content: "released")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        let stream = await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "start", permissionMode: .askForApproval
            ))
        let consumer = Task { for await event in stream { await events.append(event) } }

        await gate.waitUntilStarted()
        let steered = AgentTranscriptMessage(role: .user, text: "also inspect logs")
        #expect(await runtime.steer(steered))
        await gate.release()
        await consumer.value

        let captured = await requests.values
        #expect(captured.count == 2)
        #expect(
            captured.last?.messages.contains {
                $0.role == .user && $0.text == "also inspect logs"
            } == true)
        // Announced by identity, so a reader can retire the queued row it drew
        // without comparing one piece of text against another.
        #expect(
            await events.values.contains { event in
                guard case .steeringDelivered(let message) = event else { return false }
                return message.id == steered.id && message.text == steered.text
            })
        let providerItems = captured.last?.messages
            .first(where: { $0.role == .assistant })?.providerItems
        #expect(providerItems?.count == 1)
        #expect(
            providerItems?.first?.objectValue?["encrypted_content"]?.stringValue
                == "final-state"
        )
    }

    /// The regression that made steering pointless: a reply with nothing to run
    /// ended the run on the spot, so anything typed while it was being written
    /// was left on screen as a turn the model was never shown.
    @Test
    func steeringKeepsARunAliveThroughATurnThatAsksForNoTools() async {
        let requests = RequestRecorder()
        let gate = AsyncGate()
        let repository = InMemoryAgentRunRepository()
        let runtime = AgentRuntime(
            model: GatedAgentModel(requests: requests, gate: gate), tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        var runID: UUID?
        var states: [AgentRunState] = []
        let stream = await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "start", permissionMode: .askForApproval
            ))
        let consumer = Task {
            for await event in stream {
                if case .runState(let state) = event { states.append(state) }
                runID = runID ?? event.associatedRunID
            }
            return (runID, states)
        }

        await gate.waitUntilStarted()
        #expect(await runtime.steer(AgentTranscriptMessage(role: .user, text: "one more thing")))
        await gate.release()
        let (id, observed) = await consumer.value

        let captured = await requests.values
        #expect(captured.count == 2, "the queued message has to buy another turn")
        #expect(captured.last?.messages.contains { $0.text == "one more thing" } == true)
        #expect(observed.contains(.completed))
        let saved = await repository.snapshot(try! #require(id))?.messages
        #expect(saved?.contains { $0.text == "one more thing" } == true)
    }

    /// The line in `cancel()` that this guards is easy to lose: the batch runs
    /// in an unstructured task, so cancelling the run does not reach it by
    /// itself, and Stop would leave every running tool running.
    @Test
    func stoppingARunCancelsTheToolsItIsWaitingOn() async {
        let cancelled = Recorder()
        let gate = AsyncGate()
        let runtime = AgentRuntime(
            model: ScriptedAgentModel(turns: [
                [
                    .toolCallSnapshot(id: "1", providerItemID: nil, name: "hang", arguments: "{}"),
                    .finished(.toolCalls),
                ],
                [.textDelta("done"), .finished(.completed)],
            ]),
            tools: [hangingTool(gate, onCancel: cancelled)],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        let stream = await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "start", permissionMode: .askForApproval
            ))
        let consumer = Task { for await _ in stream {} }

        await gate.waitUntilStarted()
        await runtime.cancel()
        await consumer.value

        #expect(await cancelled.values == ["hang"])
    }

    /// A queue nobody will drain is worse than a refusal: the caller still has
    /// the words and can put them back in front of the user.
    @Test
    func steeringIsRefusedOnceThereIsNoRunLeftToDeliverIt() async {
        let repository = InMemoryAgentRunRepository()
        let runtime = AgentRuntime(
            model: ScriptedAgentModel(turns: [[.textDelta("done"), .finished(.completed)]]),
            tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        var runID: UUID?
        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "start", permissionMode: .askForApproval
            ))
        {
            runID = runID ?? event.associatedRunID
        }

        #expect(await runtime.steer(AgentTranscriptMessage(role: .user, text: "too late")) == false)
        let saved = await repository.snapshot(try! #require(runID))?.messages
        #expect(saved?.contains { $0.text == "too late" } == false)
    }

    @Test
    func schemaFailureHappensBeforeApprovalAndExecution() async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(id: "1", name: "write", arguments: "{}"),
                .finished(.toolCalls),
            ],
            [.textDelta("rejected"), .finished(.completed)],
        ])
        let approvals = Counter()
        let executions = Counter()
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "write", summary: "write",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["path": .object(["type": .string("string")])]),
                    "required": .array([.string("path")]),
                    "additionalProperties": .bool(false),
                ]),
                target: .host, approvalPolicy: .ask
            )
        ) { invocation, _ in
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "unexpected")
        }
        let broker = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { _ in
                await approvals.increment()
                return .allow
            }
        )
        let runtime = AgentRuntime(model: model, tools: [tool], approval: broker)
        for await _ in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "write", permissionMode: .askForApproval
            ))
        {}

        #expect(await approvals.value == 0)
        #expect(await executions.value == 0)
    }

    @Test(arguments: ["", "null{}provider-duplicate"])
    func zeroParameterToolReceivesAnEmptyObjectForCompatibleArguments(arguments: String) async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(id: "1", name: "list_hosts", arguments: arguments),
                .finished(.toolCalls),
            ],
            [.textDelta("done"), .finished(.completed)],
        ])
        let executions = Counter()
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "list_hosts", summary: "list",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .host, approvalPolicy: .approve
            )
        ) { invocation, _ in
            #expect(invocation.call.arguments == .object([:]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "[]")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        for await _ in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "list", permissionMode: .askForApproval
            ))
        {}
        #expect(await executions.value == 1)
    }

    @Test
    func approvalModesRouteOnlyApproveForMeToReviewer() async {
        let descriptor = AgentToolDescriptor(
            name: "write", summary: "write", inputSchema: .object([:]),
            target: .host, approvalPolicy: .ask
        )
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "1", name: "write", arguments: .object([:]))
        )
        let request = AgentApprovalRequest(
            invocation: invocation, descriptor: descriptor, userIntent: "change it"
        )
        let manual = Counter()
        let reviewer = FixedReviewer(
            result: .success(
                GuardianDecision(
                    verdict: .approve, risk: .medium, userAuthorization: .high, reason: "ok"
                )))
        let broker = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { _ in
                await manual.increment()
                return .allow
            }
        )

        #expect(await broker.authorize(request, mode: .askForApproval) == .allow)
        #expect(await manual.value == 1)
        #expect(await broker.authorize(request, mode: .approveForMe) == .allow)
        #expect(await manual.value == 1)
        #expect(await broker.authorize(request, mode: .fullAccess) == .allow)
        #expect(await manual.value == 1)
    }

    @Test
    func executionTimeEscalationUsesTheActivePermissionModeAndReceivesPreflightMetadata() async {
        let manual = Counter()
        let reviewer = CountingReviewer()
        let executions = Counter()

        for mode in AgentPermissionMode.allCases {
            let model = ScriptedAgentModel(turns: [
                [
                    .toolCallDelta(id: "1", name: "escalate", arguments: "{}"),
                    .finished(.toolCalls),
                ],
                [.textDelta("done"), .finished(.completed)],
            ])
            let descriptor = AgentToolDescriptor(
                name: "escalate", summary: "escalate",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .network, approvalPolicy: .approve
            )
            let tool = AnyAgentTool(
                descriptor: descriptor,
                preflight: { invocation in
                    AgentToolPreflight(
                        invocation: invocation, approvalPolicy: .approve,
                        executionMetadata: ["scope": .string("public")]
                    )
                },
                execute: { invocation, context in
                    #expect(context.preflightMetadata["scope"] == .string("public"))
                    var escalation = descriptor
                    escalation.approvalPolicy = .ask
                    let decision = await context.authorize(
                        AgentApprovalRequest(
                            invocation: invocation, descriptor: escalation,
                            userIntent: context.userIntent,
                            localReasons: ["redirect entered a restricted origin"]
                        ))
                    guard decision == .allow else {
                        return AgentToolResult(
                            callID: invocation.call.id, content: "denied", isError: true
                        )
                    }
                    await executions.increment()
                    return AgentToolResult(callID: invocation.call.id, content: "ok")
                }
            )
            let runtime = AgentRuntime(
                model: model, tools: [tool],
                approval: AgentApprovalBroker(
                    reviewer: reviewer,
                    manualApproval: { _ in
                        await manual.increment()
                        return .allow
                    }
                )
            )
            for await _ in await runtime.start(
                AgentRunRequest(
                    conversationID: UUID(), prompt: "follow it", permissionMode: mode
                ))
            {}
        }

        #expect(await manual.value == 1)
        #expect(await reviewer.count == 1)
        #expect(await executions.value == 3)
    }

    @Test
    func reviewerFailureAndCriticalRiskFailClosed() async {
        let descriptor = AgentToolDescriptor(
            name: "delete", summary: "delete", inputSchema: .object([:]),
            target: .host, approvalPolicy: .ask
        )
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(), call: AgentToolCall(id: "1", name: "delete", arguments: .object([:]))
            ),
            descriptor: descriptor, userIntent: "clean up"
        )
        let failed = AgentApprovalBroker(
            reviewer: FixedReviewer(result: .failure(ReviewFailure())),
            manualApproval: { _ in .allow }
        )
        guard case .deny = await failed.authorize(request, mode: .approveForMe) else {
            Issue.record("Expected fail-closed denial")
            return
        }

        let critical = AgentApprovalBroker(
            reviewer: FixedReviewer(
                result: .success(
                    GuardianDecision(
                        verdict: .approve, risk: .critical,
                        userAuthorization: .high, reason: "critical"
                    ))),
            manualApproval: { _ in .allow }
        )
        #expect(
            await critical.authorize(request, mode: .approveForMe)
                == .deny("critical")
        )
    }

    @Test
    func reviewerTimeoutFailsClosedAndReportsTimeout() async {
        let request = AgentApprovalRequest(
            invocation: AgentToolInvocation(
                runID: UUID(),
                call: AgentToolCall(id: "1", name: "write", arguments: .object([:]))
            ),
            descriptor: AgentToolDescriptor(
                name: "write", summary: "write", inputSchema: .object([:]),
                target: .host, approvalPolicy: .ask
            ),
            userIntent: "change it"
        )
        let events = EventRecorder()
        let broker = AgentApprovalBroker(
            reviewer: HangingReviewer(), manualApproval: { _ in .allow },
            reviewTimeout: .milliseconds(10),
            event: { event in Task { await events.append(event) } }
        )

        guard case .deny = await broker.authorize(request, mode: .approveForMe) else {
            Issue.record("Expected timeout denial")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
        #expect(
            await events.values.contains {
                if case .reviewFailed(_, _, let timedOut) = $0 { return timedOut }
                return false
            })
    }

    /// Returning a bare error result left the transcript with an empty
    /// assistant turn and no card, which reads as "the model said nothing"
    /// rather than "the model called a tool that is not registered".
    @Test
    func anUnknownToolStillProducesACard() async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(id: "1", name: "not_registered", arguments: "{}"),
                .finished(.toolCalls),
            ],
            [.textDelta("recovered"), .finished(.completed)],
        ])
        let runtime = AgentRuntime(
            model: model, tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        var events: [AgentEvent] = []
        for await event in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
            ))
        { events.append(event) }

        #expect(
            events.contains {
                if case .toolProposed(let invocation, _) = $0 {
                    invocation.call.name == "not_registered"
                } else {
                    false
                }
            })
        #expect(
            events.contains {
                if case .toolFinished(_, let result) = $0 { result.isError } else { false }
            })
        // The loop still recovers: the model is told, and answers.
        #expect(events.contains(.runState(.completed)))
    }

    /// `Dictionary(uniqueKeysWithValues:)` traps on a duplicate, and tool names
    /// partly come from remote MCP servers.
    @Test
    func duplicateToolNamesAreResolvedRatherThanTrapping() async {
        let executed = Recorder()
        let tools = ["builtin", "mcp-shadow"].map { origin in
            AnyAgentTool(
                descriptor: AgentToolDescriptor(
                    name: "list_hosts", summary: origin,
                    inputSchema: .object([
                        "type": .string("object"), "properties": .object([:]),
                        "required": .array([]), "additionalProperties": .bool(false),
                    ]),
                    target: .host, approvalPolicy: .approve
                )
            ) { invocation, _ in
                await executed.append(origin)
                return AgentToolResult(callID: invocation.call.id, content: origin)
            }
        }
        let runtime = AgentRuntime(
            model: ScriptedAgentModel(turns: [
                [.toolCallDelta(id: "1", name: "list_hosts", arguments: "{}"), .finished(.toolCalls)],
                [.textDelta("done"), .finished(.completed)],
            ]),
            tools: tools,
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        for await _ in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "list", permissionMode: .askForApproval
            ))
        {}

        // First registration wins, so a remote name cannot shadow a built-in.
        #expect(await executed.values == ["builtin"])
    }

    /// Every event used to be handed to the repository, which meant an
    /// unstructured task and a `ModelContext.save()` per streamed token.
    @Test
    func onlyRunScopedEventsReachTheRepository() async {
        let repository = RecordingRunRepository()
        let runtime = AgentRuntime(
            model: ScriptedAgentModel(turns: [
                [
                    .textDelta("one"), .textDelta("two"), .textDelta("three"),
                    .toolCallDelta(id: "1", name: "noop", arguments: "{}"),
                    .finished(.toolCalls),
                ],
                [.textDelta("done"), .finished(.completed)],
            ]),
            tools: [
                AnyAgentTool(
                    descriptor: AgentToolDescriptor(
                        name: "noop", summary: "noop",
                        inputSchema: .object([
                            "type": .string("object"), "properties": .object([:]),
                            "required": .array([]), "additionalProperties": .bool(false),
                        ]),
                        target: .local, approvalPolicy: .approve
                    )
                ) { invocation, _ in
                    AgentToolResult(callID: invocation.call.id, content: "ok")
                }
            ],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        for await _ in await runtime.start(
            AgentRunRequest(
                conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
            ))
        {}
        try? await Task.sleep(for: .milliseconds(50))

        let recorded = await repository.recorded
        #expect(!recorded.isEmpty)
        #expect(recorded.allSatisfy { $0.isDurable })
        #expect(!recorded.contains { if case .messageDelta = $0 { true } else { false } })
        #expect(!recorded.contains { if case .runState = $0 { true } else { false } })
    }

    @Test
    func mcpToolNamesThatSanitizeAlikeStayDistinct() {
        var server = MCPServer(name: "Gateway")
        server.tools = [
            MCPTool(id: "list-hosts"), MCPTool(id: "list.hosts"), MCPTool(id: "list_hosts"),
        ]
        let descriptors = AgentMCPTools.make(servers: [(server: server, bearerToken: nil)])
            .map(\.descriptor)
        let names = descriptors.map(\.qualifiedName)

        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("gateway.") })
        #expect(descriptors.allSatisfy { $0.namespace == "gateway" })
        #expect(descriptors.map(\.name).contains("list_hosts_2"))
        #expect(
            descriptors.allSatisfy {
                $0.presentation?.activity == .label($0.qualifiedName)
            })
    }

    @Test
    func mcpToolAccessPoliciesControlApprovalWithoutHidingTools() throws {
        var server = MCPServer(name: "Gateway")
        var destructive = MCPTool(id: "destructive", accessPolicy: .approve)
        destructive.annotations.destructiveHint = true
        server.tools = [
            MCPTool(id: "denied", accessPolicy: .deny),
            MCPTool(id: "asked", accessPolicy: .ask),
            MCPTool(id: "approved", accessPolicy: .approve),
            destructive,
        ]

        let descriptors = AgentMCPTools.make(servers: [(server: server, bearerToken: nil)])
            .map(\.descriptor)
        #expect(descriptors.count == 4)
        #expect(descriptors.first { $0.name == "denied" }?.approvalPolicy == .deny)
        #expect(descriptors.first { $0.name == "asked" }?.approvalPolicy == .ask)
        #expect(descriptors.first { $0.name == "approved" }?.approvalPolicy == .approve)
        #expect(descriptors.first { $0.name == "destructive" }?.approvalPolicy == .approve)
        #expect(descriptors.first { $0.name == "destructive" }?.concurrency == .sequential)
    }

}

private actor Recorder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

/// Announces that it started, then waits to be cancelled rather than to finish.
///
/// The sleep is long enough that finishing normally is never the fast path, and
/// short enough that a test which fails to cancel it fails rather than hangs.
private func hangingTool(_ gate: AsyncGate, onCancel: Recorder? = nil) -> AnyAgentTool {
    AnyAgentTool(
        descriptor: AgentToolDescriptor(
            name: "hang", summary: "hang",
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .local, approvalPolicy: .approve, concurrency: .parallel
        )
    ) { invocation, _ in
        await gate.begin()
        do {
            try await Task.sleep(for: .seconds(30))
        } catch {
            await onCancel?.append("hang")
            throw error
        }
        return AgentToolResult(callID: invocation.call.id, content: "ran to completion")
    }
}

private actor RecordingRunRepository: AgentRunPersisting {
    var recorded: [AgentEvent] = []
    func save(_ snapshot: AgentRunSnapshot) {}
    func record(_ event: AgentEvent, runID: UUID) { recorded.append(event) }
    func persistCompaction(
        _ record: AgentCompactionRecord, conversationID: UUID
    ) {}
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
    func setConversationMetadata(
        _ metadata: StoredAgentConversationMetadata, conversationID: UUID
    ) {}
    func reorderConversations(_ updates: [StoredAgentConversationOrder]) {}
    func truncateConversation(
        _ id: UUID, fromUserMessageID messageID: UUID,
        replacingWith message: AgentTranscriptMessage
    ) {}
    func createConversation(_ conversation: StoredAgentConversation) {}
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}

private actor EventRecorder {
    var values: [AgentEvent] = []
    func append(_ value: AgentEvent) { values.append(value) }
}

private actor RequestRecorder {
    var values: [AgentModelRequest] = []
    func append(_ value: AgentModelRequest) { values.append(value) }
}

private actor AsyncGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    /// Announce arrival without blocking on release — for work that is meant to
    /// be ended by cancellation rather than let through.
    func begin() {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func beginAndWait() async {
        begin()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

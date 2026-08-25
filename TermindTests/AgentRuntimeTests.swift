import Foundation
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
        func next() -> Int { defer { value += 1 }; return value }
    }
}

private struct FixedReviewer: SecurityReviewing {
    var result: Result<SecurityReviewDecision, any Error>
    func review(_ request: AgentApprovalRequest) async throws -> SecurityReviewDecision { try result.get() }
}

private struct ReviewFailure: Error {}

private struct HangingReviewer: SecurityReviewing {
    func review(_ request: AgentApprovalRequest) async throws -> SecurityReviewDecision {
        try await Task.sleep(for: .seconds(30))
        return SecurityReviewDecision(
            verdict: .approve, risk: .low,
            userAuthorization: .sufficient, reason: "late"
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
                    continuation.yield(.providerItem(.object([
                        "type": .string("reasoning"), "id": .string("reasoning-1"),
                    ])))
                    continuation.yield(.providerItem(.object([
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
    func sessionContextIsStableAcrossToolTurnsAndExcludedFromTranscript() async {
        let requests = RequestRecorder()
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
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "inspect", summary: "inspect",
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .local, safety: .locallyReadOnly
        )) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: "ok")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
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

        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "inspect", permissionMode: .askForApproval,
            sessionContext: context
        )) {}

        let captured = await requests.values
        #expect(captured.count == 2)
        #expect(captured.allSatisfy {
            $0.systemPrompt.contains("host: edge-01")
                && $0.systemPrompt.contains("cwd: /srv/app")
                && $0.systemPrompt.contains("distribution_id: alpine")
                && $0.systemPrompt.contains("kernel_release: 6.6.44-0-lts")
                && $0.systemPrompt.contains("architecture: aarch64")
        })
        #expect(captured.allSatisfy { request in
            request.messages.allSatisfy {
                !$0.text.contains("distribution_id:") && !$0.text.contains("cwd:")
            }
        })
        #expect(captured.first?.messages.first?.text == "inspect")
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
                    target: .local, safety: .locallyReadOnly
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
        let model = CapturingAgentModel(requests: requests)
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "wait", summary: "wait",
            inputSchema: .object(["type": .string("object")]),
            target: .local, safety: .locallyReadOnly
        )) { invocation, _ in
            await gate.beginAndWait()
            return AgentToolResult(callID: invocation.call.id, content: "released")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        let stream = await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "start", permissionMode: .askForApproval
        ))
        let consumer = Task { for await _ in stream {} }

        await gate.waitUntilStarted()
        await runtime.steer("also inspect logs")
        await gate.release()
        await consumer.value

        let captured = await requests.values
        #expect(captured.count == 2)
        #expect(captured.last?.messages.contains {
            $0.role == .user && $0.text == "also inspect logs"
        } == true)
        let providerItems = captured.last?.messages
            .first(where: { $0.role == .assistant })?.providerItems
        #expect(providerItems?.count == 1)
        #expect(
            providerItems?.first?.objectValue?["encrypted_content"]?.stringValue
                == "final-state"
        )
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
                target: .host, safety: .requiresAuthorization
            )
        ) { invocation, _ in
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "unexpected")
        }
        let broker = AgentApprovalBroker(
            reviewer: nil,
            manualApproval: { _ in await approvals.increment(); return .allow }
        )
        let runtime = AgentRuntime(model: model, tools: [tool], approval: broker)
        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "write", permissionMode: .askForApproval
        )) {}

        #expect(await approvals.value == 0)
        #expect(await executions.value == 0)
    }

    @Test
    func emptyCompatibleToolArgumentsBecomeAnEmptyObject() async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(id: "1", name: "list_hosts", arguments: ""),
                .finished(.toolCalls),
            ],
            [.textDelta("done"), .finished(.completed)],
        ])
        let executions = Counter()
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "list_hosts", summary: "list",
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .host, safety: .locallyReadOnly
        )) { invocation, _ in
            #expect(invocation.call.arguments == .object([:]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "[]")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "list", permissionMode: .askForApproval
        )) {}
        #expect(await executions.value == 1)
    }

    @Test
    func zeroParameterToolIgnoresMalformedCompatibleArguments() async {
        let model = ScriptedAgentModel(turns: [
            [
                .toolCallDelta(
                    id: "1", name: "list_hosts",
                    arguments: "null{}provider-duplicate"
                ),
                .finished(.toolCalls),
            ],
            [.textDelta("done"), .finished(.completed)],
        ])
        let executions = Counter()
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "list_hosts", summary: "list",
            inputSchema: .object([
                "type": .string("object"), "properties": .object([:]),
                "required": .array([]), "additionalProperties": .bool(false),
            ]),
            target: .host, safety: .locallyReadOnly
        )) { invocation, _ in
            #expect(invocation.call.arguments == .object([:]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "[]")
        }
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )
        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "list", permissionMode: .askForApproval
        )) {}
        #expect(await executions.value == 1)
    }

    @Test
    func approvalModesRouteOnlyApproveForMeToReviewer() async {
        let descriptor = AgentToolDescriptor(
            name: "write", summary: "write", inputSchema: .object([:]),
            target: .host, safety: .requiresAuthorization
        )
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "1", name: "write", arguments: .object([:]))
        )
        let request = AgentApprovalRequest(
            invocation: invocation, descriptor: descriptor, userIntent: "change it"
        )
        let manual = Counter()
        let reviewer = FixedReviewer(result: .success(SecurityReviewDecision(
            verdict: .approve, risk: .medium, userAuthorization: .sufficient, reason: "ok"
        )))
        let broker = AgentApprovalBroker(
            reviewer: reviewer,
            manualApproval: { _ in await manual.increment(); return .allow }
        )

        #expect(await broker.authorize(request, mode: .askForApproval) == .allow)
        #expect(await manual.value == 1)
        #expect(await broker.authorize(request, mode: .approveForMe) == .allow)
        #expect(await manual.value == 1)
        #expect(await broker.authorize(request, mode: .fullAccess) == .allow)
        #expect(await manual.value == 1)
    }

    @Test
    func reviewerFailureAndCriticalRiskFailClosed() async {
        let descriptor = AgentToolDescriptor(
            name: "delete", summary: "delete", inputSchema: .object([:]),
            target: .host, safety: .requiresAuthorization
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
            reviewer: FixedReviewer(result: .success(SecurityReviewDecision(
                verdict: .approve, risk: .critical,
                userAuthorization: .sufficient, reason: "critical"
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
                target: .host, safety: .requiresAuthorization
            ),
            userIntent: "change it"
        )
        let events = EventRecorder()
        let broker = AgentApprovalBroker(
            reviewer: HangingReviewer(), manualApproval: { _ in .allow },
            reviewTimeout: .milliseconds(10),
            event: { event in Task { await events.append(event) } }
        )

        guard case .deny(let reason) = await broker.authorize(request, mode: .approveForMe) else {
            Issue.record("Expected timeout denial")
            return
        }
        #expect(reason.contains("timed out"))
        try? await Task.sleep(for: .milliseconds(10))
        #expect(await events.values.contains {
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
        for await event in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
        )) { events.append(event) }

        #expect(events.contains {
            if case .toolProposed(let invocation, _) = $0 {
                invocation.call.name == "not_registered"
            } else { false }
        })
        #expect(events.contains {
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
            AnyAgentTool(descriptor: AgentToolDescriptor(
                name: "list_hosts", summary: origin,
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .host, safety: .locallyReadOnly
            )) { invocation, _ in
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
        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "list", permissionMode: .askForApproval
        )) {}

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
            tools: [AnyAgentTool(descriptor: AgentToolDescriptor(
                name: "noop", summary: "noop",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .local, safety: .locallyReadOnly
            )) { invocation, _ in
                AgentToolResult(callID: invocation.call.id, content: "ok")
            }],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )
        for await _ in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
        )) {}
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
        let names = AgentMCPTools.make(servers: [(server: server, bearerToken: nil)])
            .map(\.descriptor.name)

        #expect(Set(names).count == 3)
        #expect(names.allSatisfy { $0.hasPrefix("mcp__") })
    }

    @Test
    func secretHandlesAreSingleUseAndBindingScoped() async throws {
        let broker = SecretBroker()
        let binding = SecretBinding(
            runID: UUID(), toolName: "ssh_exec", hostID: UUID(), purpose: "sudo"
        )
        let handle = await broker.issue("password", binding: binding)

        await #expect(throws: SecretBrokerError.bindingMismatch) {
            try await broker.consume(
                handle,
                matching: SecretBinding(
                    runID: binding.runID, toolName: "fetch",
                    hostID: binding.hostID, purpose: binding.purpose
                )
            )
        }
        #expect(try await broker.consume(handle, matching: binding) == "password")
        await #expect(throws: SecretBrokerError.notFound) {
            try await broker.consume(handle, matching: binding)
        }
    }
}

private actor Recorder {
    var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor RecordingRunRepository: AgentRunPersisting {
    var recorded: [AgentEvent] = []
    func save(_ snapshot: AgentRunSnapshot) {}
    func record(_ event: AgentEvent, runID: UUID) { recorded.append(event) }
    func loadConversations() -> [StoredAgentConversation] { [] }
    func deleteConversation(_ id: UUID) {}
    func setTitle(_ title: String, conversationID: UUID) {}
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

    func beginAndWait() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
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

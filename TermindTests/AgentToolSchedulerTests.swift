import Foundation
import Testing

@testable import Termind

/// Records how many tool executions were in flight at once.
///
/// Peak rather than a barrier: a barrier proves overlap more sharply but hangs
/// forever when the behaviour regresses to serial, and a hung suite reports
/// nothing. Each tool holds its slot for long enough that a genuinely parallel
/// batch cannot miss the overlap, while a serial one can never manufacture it.
private actor ConcurrencyProbe {
    private var active = 0
    private(set) var peak = 0
    private(set) var order: [String] = []

    func enter(_ name: String) {
        active += 1
        peak = max(peak, active)
        order.append(name)
    }

    func leave() { active -= 1 }
}

private actor ScriptedTurns: AgentModelStreaming {
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

private actor EventLog {
    private(set) var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

/// One turn asking for `names`, then a plain answer.
private func callingTurns(_ names: [String]) -> [[AgentModelStreamEvent]] {
    [
        names.enumerated().map { index, name in
            .toolCallSnapshot(
                id: "call-\(index)", providerItemID: nil, name: name, arguments: "{}"
            )
        } + [.finished(.toolCalls)],
        [.textDelta("done"), .finished(.completed)],
    ]
}

private let emptySchema = AgentJSONValue.object([
    "type": .string("object"), "properties": .object([:]),
    "required": .array([]), "additionalProperties": .bool(false),
])

private func probeTool(
    _ name: String,
    concurrency: AgentToolDescriptor.Concurrency,
    safety: AgentToolDescriptor.Safety = .locallyReadOnly,
    preflightConcurrency: AgentToolDescriptor.Concurrency? = nil,
    probe: ConcurrencyProbe
) -> AnyAgentTool {
    let descriptor = AgentToolDescriptor(
        name: name, summary: name, inputSchema: emptySchema,
        target: .local, safety: safety, concurrency: concurrency
    )
    return AnyAgentTool(
        descriptor: descriptor,
        preflight: { invocation in
            AgentToolPreflight(
                invocation: invocation, safety: safety, concurrency: preflightConcurrency
            )
        },
        execute: { invocation, _ in
            await probe.enter(name)
            // Long enough that two children of the same task group cannot fail
            // to overlap, short enough to keep the suite quick.
            try? await Task.sleep(for: .milliseconds(80))
            await probe.leave()
            return AgentToolResult(callID: invocation.call.id, content: name)
        }
    )
}

private func drain(
    _ runtime: AgentRuntime, prompt: String = "go",
    mode: ChatPermissionMode = .askForApproval
) async -> [AgentEvent] {
    var events: [AgentEvent] = []
    for await event in await runtime.start(AgentRunRequest(
        conversationID: UUID(), prompt: prompt, permissionMode: mode
    )) { events.append(event) }
    return events
}

private func allowingRuntime(
    tools: [AnyAgentTool],
    turns: [[AgentModelStreamEvent]],
    hooks: [any AgentLoopHook] = [],
    configuration: AgentLoopConfiguration = AgentLoopConfiguration()
) -> AgentRuntime {
    AgentRuntime(
        model: ScriptedTurns(turns), tools: tools,
        approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
        hooks: hooks, configuration: configuration
    )
}

private func toolResults(_ events: [AgentEvent]) -> [String] {
    events.compactMap {
        if case .toolFinished(_, let result) = $0 { result.content } else { nil }
    }
}

@Suite
struct AgentToolSchedulerTests {
    @Test
    func aBatchOfParallelToolsOverlapsAndStillReportsInSourceOrder() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: ["alpha", "beta", "gamma"].map {
                probeTool($0, concurrency: .parallel, probe: probe)
            },
            turns: callingTurns(["gamma", "alpha", "beta"])
        )

        let events = await drain(runtime)

        #expect(await probe.peak >= 2, "the batch did not overlap")
        // Completion order is the network's business. What the model is shown
        // is not: the transcript follows the order it asked in.
        let calls = events.compactMap { event -> String? in
            if case .toolProposed(let invocation, _) = event { invocation.call.name } else { nil }
        }
        #expect(calls == ["gamma", "alpha", "beta"])
    }

    /// Pi's rule, and the one that keeps this safe: a tool that must not run
    /// beside anything takes the whole turn with it rather than being fenced
    /// off into its own segment.
    @Test
    func oneSequentialToolMakesTheWholeBatchSerial() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: [
                probeTool("read-a", concurrency: .parallel, probe: probe),
                probeTool("read-b", concurrency: .parallel, probe: probe),
                probeTool("write", concurrency: .sequential, probe: probe),
            ],
            turns: callingTurns(["read-a", "read-b", "write"])
        )

        _ = await drain(runtime)

        #expect(await probe.peak == 1)
        #expect(await probe.order == ["read-a", "read-b", "write"])
    }

    /// `ssh_exec` decides per command, not per tool: the classifier proves a
    /// command safe and preflight hands that same evidence to the scheduler.
    @Test
    func preflightOverridesTheDeclaredConcurrencyInBothDirections() async {
        let promoted = ConcurrencyProbe()
        let promotedRuntime = allowingRuntime(
            tools: ["one", "two"].map {
                probeTool(
                    $0, concurrency: .sequential, preflightConcurrency: .parallel, probe: promoted
                )
            },
            turns: callingTurns(["one", "two"])
        )
        _ = await drain(promotedRuntime)
        #expect(await promoted.peak >= 2, "preflight did not promote the calls to parallel")

        let demoted = ConcurrencyProbe()
        let demotedRuntime = allowingRuntime(
            tools: [
                probeTool("safe", concurrency: .parallel, probe: demoted),
                probeTool(
                    "risky", concurrency: .parallel, preflightConcurrency: .sequential,
                    probe: demoted
                ),
            ],
            turns: callingTurns(["safe", "risky"])
        )
        _ = await drain(demotedRuntime)
        #expect(await demoted.peak == 1, "one demoted call did not serialize its batch")
    }

    /// A refused turn must still answer every call it refused. An assistant
    /// message whose tool calls go unanswered is rejected outright by every
    /// provider on the *next* request, so the alternative is a conversation
    /// that can never be continued.
    @Test
    func aBudgetRefusalStillProducesOneResultPerCall() async {
        var configuration = AgentLoopConfiguration()
        configuration.maxToolCalls = 2
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: ["a", "b", "c"].map { probeTool($0, concurrency: .parallel, probe: probe) },
            turns: callingTurns(["a", "b", "c"]),
            configuration: configuration
        )

        let events = await drain(runtime)

        #expect(await probe.order.isEmpty, "a refused batch must not run anything")
        #expect(toolResults(events).count == 3)
        #expect(events.contains {
            if case .toolFinished(_, let result) = $0 { result.isError } else { false }
        })
    }

    /// Salvaged arguments can parse and validate and still be silently
    /// incomplete, so a truncated turn is refused rather than executed — and,
    /// again, refused with an answer for every call.
    @Test
    func aTruncatedTurnRefusesEveryCallWithoutRunningIt() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: [probeTool("write", concurrency: .parallel, probe: probe)],
            turns: [
                [
                    .toolCallSnapshot(
                        id: "call-0", providerItemID: nil, name: "write", arguments: "{}"
                    ),
                    .finished(.length),
                ],
                [.textDelta("done"), .finished(.completed)],
            ]
        )

        let events = await drain(runtime)

        #expect(await probe.order.isEmpty)
        #expect(toolResults(events).count == 1)
        #expect(events.contains { if case .runState(.failed) = $0 { true } else { false } })
    }

    @Test
    func hooksCanBlockACallAndRewriteAResult() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: [
                probeTool("blocked", concurrency: .parallel, probe: probe),
                probeTool("allowed", concurrency: .parallel, probe: probe),
            ],
            turns: callingTurns(["blocked", "allowed"]),
            hooks: [BlockingHook(name: "blocked"), AuditingHook()]
        )

        let events = await drain(runtime)

        #expect(await probe.order == ["allowed"], "the blocked call still executed")
        let results = toolResults(events)
        #expect(results.contains { $0.contains("policy says no") })
        // Every result passes the after-hooks, including the blocked one.
        #expect(results.allSatisfy { $0.hasSuffix(" [audited]") })
    }

    @Test
    func aStoppingHookEndsTheRunAfterTheTurnRatherThanAbandoningIt() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: [probeTool("look", concurrency: .parallel, probe: probe)],
            turns: callingTurns(["look"]),
            hooks: [StoppingHook()]
        )

        let events = await drain(runtime)

        #expect(await probe.order == ["look"], "the turn's tools should still have run")
        #expect(events.contains(.runState(.completed)))
        // Stopped after turn 0, so the second model round trip never happened.
        #expect(!events.contains { if case .turnStarted(1) = $0 { true } else { false } })
    }

    @Test
    func runAndTurnBoundariesBracketEachModelRoundTrip() async {
        let probe = ConcurrencyProbe()
        let runtime = allowingRuntime(
            tools: [probeTool("look", concurrency: .parallel, probe: probe)],
            turns: callingTurns(["look"])
        )

        let events = await drain(runtime)

        var trace: [String] = []
        for event in events {
            switch event {
            case .runStarted: trace.append("run")
            case .turnStarted(let index): trace.append("start-\(index)")
            case .turnFinished(let index, let reason): trace.append("end-\(index)-\(reason)")
            default: break
            }
        }
        #expect(trace == ["run", "start-0", "end-0-toolCalls", "start-1", "end-1-completed"])
    }
}

// MARK: - Hooks under test

private struct BlockingHook: AgentLoopHook {
    let name: String

    func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision {
        context.descriptor.name == name ? .block(reason: "policy says no") : .proceed
    }
}

private struct AuditingHook: AgentLoopHook {
    func didExecute(_ context: AgentToolResultContext) async -> AgentToolResultOverride? {
        AgentToolResultOverride(content: context.result.content + " [audited]")
    }
}

private struct StoppingHook: AgentLoopHook {
    func shouldStop(after summary: AgentTurnSummary) async -> Bool { true }
}

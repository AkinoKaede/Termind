import Foundation
import Testing

@testable import Termind

private let emptySchema = AgentJSONValue.object([
    "type": .string("object"), "properties": .object([:]),
    "required": .array([]), "additionalProperties": .bool(false),
])

private actor RequestLog {
    var values: [AgentModelRequest] = []
    func append(_ value: AgentModelRequest) { values.append(value) }
}

private struct TwoTurnModel: AgentModelStreaming {
    let requests: RequestLog
    let counter = Counter()

    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                await requests.append(request)
                if await counter.next() == 0 {
                    continuation.yield(.toolCallSnapshot(
                        id: "1", providerItemID: nil, name: "slow", arguments: "{}"
                    ))
                    continuation.yield(.finished(.toolCalls))
                } else {
                    continuation.yield(.textDelta("done"))
                    continuation.yield(.finished(.completed))
                }
                continuation.finish()
            }
        }
    }

    actor Counter {
        var value = 0
        func next() -> Int { defer { value += 1 }; return value }
    }
}

/// Pi's `onUpdate`, ported: a tool may say what it has so far, and the loop
/// neither waits for it nor tells the model about it.
@Suite
struct AgentToolProgressTests {

    @Test
    func partialsReachTheCardAndOnlyTheFinalResultReachesTheModel() async {
        let requests = RequestLog()
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "slow", summary: "slow", inputSchema: emptySchema,
            target: .local, safety: .locallyReadOnly, concurrency: .parallel
        )) { invocation, context in
            context.report(AgentToolResult(callID: invocation.call.id, content: "10 of 20"))
            context.report(AgentToolResult(callID: invocation.call.id, content: "19 of 20"))
            return AgentToolResult(callID: invocation.call.id, content: "20 of 20")
        }
        let runtime = AgentRuntime(
            model: TwoTurnModel(requests: requests), tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        var progress: [String] = []
        var finished: [String] = []
        for await event in await runtime.start(AgentRunRequest(
            conversationID: UUID(), prompt: "go", permissionMode: .askForApproval
        )) {
            if case .toolProgress(_, let partial) = event { progress.append(partial.content) }
            if case .toolFinished(_, let result) = event { finished.append(result.content) }
        }

        #expect(progress == ["10 of 20", "19 of 20"])
        #expect(finished == ["20 of 20"])

        // The model is owed one result per call, not a running commentary.
        let replayed = await requests.values.last?.messages.filter { $0.role == .tool } ?? []
        #expect(replayed.map(\.text) == ["20 of 20"])
    }

    @MainActor
    @Test
    func aProgressReportFillsTheCardWithoutFinishingIt() {
        let conversation = ConversationModel()
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "1", name: "slow", arguments: .object([:]))
        )
        let descriptor = AgentToolDescriptor(
            name: "slow", summary: "slow", inputSchema: emptySchema,
            target: .local, safety: .locallyReadOnly
        )
        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolStarted(invocation))

        conversation.handle(.toolProgress(
            invocation, AgentToolResult(callID: "1", content: "half way")
        ))

        #expect(conversation.toolCards.count == 1)
        #expect(conversation.toolCards[0].result?.content == "half way")
        // Still running: a card that showed "Completed" the moment it had
        // something to show would be lying about the command.
        #expect(conversation.toolCards[0].state == .running)
        #expect(conversation.transcript.isEmpty)
    }
}

/// The buffer between `libssh2`'s queue and the events the card is drawn from.
@Suite
struct AgentCommandOutputStreamTests {

    @Test
    func reportsCarryEverythingSoFarRatherThanTheLatestChunk() async {
        let reports = Reports()
        let stream = AgentCommandOutputStream(interval: .zero) { out, error in
            reports.append(out, error)
        }

        stream.handler(Data("one\n".utf8), false)
        stream.handler(Data("two\n".utf8), false)
        stream.handler(Data("oops\n".utf8), true)

        // The card replaces its result wholesale, so a report carrying only the
        // newest chunk would make the output flicker rather than grow.
        #expect(reports.values.map(\.0) == ["one\n", "one\ntwo\n", "one\ntwo\n"])
        #expect(reports.values.map(\.1) == ["", "", "oops\n"])
        #expect(stream.captured.standardOut == "one\ntwo\n")
        #expect(stream.captured.standardError == "oops\n")
    }

    @Test
    func chunksInsideTheIntervalAreCapturedButNotReported() async {
        let reports = Reports()
        let stream = AgentCommandOutputStream(interval: .seconds(60)) { out, error in
            reports.append(out, error)
        }

        stream.handler(Data("first".utf8), false)
        stream.handler(Data(" second".utf8), false)

        #expect(reports.values.count == 1, "the second chunk is inside the window")
        // Throttling a report must never drop the output it was reporting.
        #expect(stream.captured.standardOut == "first second")
    }

    @Test
    func captureStopsAtTheLimitTheSessionItselfUses() {
        let stream = AgentCommandOutputStream(interval: .zero, limit: 4) { _, _ in }
        stream.handler(Data("abc".utf8), false)
        stream.handler(Data("def".utf8), false)
        #expect(stream.captured.standardOut == "abcd")
    }

    /// Locked rather than an actor: the callback under test may not await, so
    /// a collector that had to be awaited would be testing something else — and
    /// would race the assertions, which is how this test first failed.
    private nonisolated final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(String, String)] = []
        var values: [(String, String)] { lock.withLock { stored } }
        func append(_ out: String, _ error: String) { lock.withLock { stored.append((out, error)) } }
    }
}

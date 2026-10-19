import AgentKit
import Foundation
import TermindApplication
import TermindRemoteInfrastructure
import Testing

private let emptySchema = AgentJSONValue.object([
    "type": .string("object"), "properties": .object([:]),
    "required": .array([]), "additionalProperties": .bool(false),
])

@Suite
struct AgentToolProgressTests {
    @MainActor
    @Test
    func aProgressReportFillsTheCardWithoutFinishingIt() {
        let conversation = ConversationModel()
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "1", name: "slow", arguments: .object([:]))
        )
        let descriptor = AgentToolDescriptor(
            name: "slow", summary: "slow", inputSchema: emptySchema,
            target: .local, approvalPolicy: .approve
        )
        conversation.handle(.toolProposed(invocation, descriptor))
        conversation.handle(.toolStarted(invocation))

        conversation.handle(
            .toolProgress(
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
        let stream = AgentCommandOutputStream(
            interval: .zero, accumulator: AgentOutputAccumulator(path: { "tests/output.txt" })
        ) { out, error in
            reports.append(out, error)
        }

        stream.handler(Data("one\n".utf8), false)
        stream.handler(Data("two\n".utf8), false)
        stream.handler(Data("oops\n".utf8), true)

        // The card replaces its result wholesale, so a report carrying only the
        // newest chunk would make the output flicker rather than grow.
        #expect(reports.values.map(\.0) == ["one\n", "one\ntwo\n", "one\ntwo\noops\n"])
        #expect(reports.values.map(\.1) == ["", "", ""])
        #expect(await stream.snapshot().output == "one\ntwo\noops\n")
    }

    @Test
    func chunksInsideTheIntervalAreCapturedButNotReported() async {
        let reports = Reports()
        let stream = AgentCommandOutputStream(
            interval: .seconds(60), accumulator: AgentOutputAccumulator(path: { "tests/output.txt" })
        ) { out, error in
            reports.append(out, error)
        }

        stream.handler(Data("first".utf8), false)
        stream.handler(Data(" second".utf8), false)

        #expect(reports.values.count == 1, "the second chunk is inside the window")
        // Throttling a report must never drop the output it was reporting.
        #expect(await stream.snapshot().output == "first second")
    }

    @Test
    func captureRetainsWholeTailLinesAndSavesTheCompleteOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = AgentScratchWorkspace(base: directory)
        let accumulator = AgentOutputAccumulator(workspace: workspace, path: { "chat/outputs/ssh-exec-test.txt" })
        let stream = AgentCommandOutputStream(interval: .zero, accumulator: accumulator) { _, _ in }
        let text = String(repeating: "first line\n", count: 7_000) + "latest>"
        stream.handler(Data(text.utf8), false)
        let snapshot = await stream.snapshot()
        #expect(snapshot.output.hasSuffix("latest>"))
        #expect(snapshot.output.utf8.count <= 65_536)
        #expect(snapshot.isTruncated)
        let path = try #require(snapshot.capture?.path)
        #expect(try await workspace.data(at: path).data == Data(text.utf8))
    }

    @Test
    func callbacksCanSplitAUnicodeScalarWithoutCorruptingTheSnapshot() async {
        let accumulator = AgentOutputAccumulator(path: { "tests/output.txt" })
        let stream = AgentCommandOutputStream(interval: .zero, accumulator: accumulator) { _, _ in }
        let text = String(repeating: "\u{1F642}\n", count: 30)
        let data = Data(text.utf8)
        stream.handler(Data(data.prefix(13)), true)
        #expect(!accumulator.preview.contains("\u{FFFD}"))
        stream.handler(Data(data.dropFirst(13)), true)
        #expect(await stream.snapshot().output == text)
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

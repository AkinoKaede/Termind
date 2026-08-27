import Foundation
import Testing

@testable import Termind

@Suite
struct AgentContextPipelineTests {
    private func context(_ messages: [AgentTranscriptMessage]) -> AgentModelContext {
        AgentModelContext(systemPrompt: "system", messages: messages, tools: [])
    }

    private func assistant(calling ids: [String]) -> AgentTranscriptMessage {
        AgentTranscriptMessage(
            role: .assistant,
            toolCalls: ids.map { AgentToolCall(id: $0, name: $0, arguments: .object([:])) }
        )
    }

    private func result(_ id: String, _ text: String = "") -> AgentTranscriptMessage {
        AgentTranscriptMessage(
            role: .tool, text: text.isEmpty ? id : text, toolCallID: id, toolName: id
        )
    }

    /// The reason this transform exists: `ConversationModel` appends results as
    /// `toolFinished` arrives, which under parallel execution is completion
    /// order, while the run's own snapshot appends in source order. The
    /// conversation's copy is what seeds the next run.
    @Test
    func toolResultsAreReorderedToMatchTheCallTheyAnswer() {
        let messages = [
            AgentTranscriptMessage(role: .user, text: "go"),
            assistant(calling: ["a", "b", "c"]),
            result("c"), result("a"), result("b"),
            AgentTranscriptMessage(role: .user, text: "next"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.compactMap(\.toolCallID) == ["a", "b", "c"])
        // Everything else keeps its place.
        #expect(ordered.first?.text == "go")
        #expect(ordered.last?.text == "next")
    }

    @Test
    func reorderingLeavesTurnsThatCalledNothingAlone() {
        let messages = [
            assistant(calling: []),
            AgentTranscriptMessage(role: .user, text: "still here"),
            assistant(calling: ["x"]),
            result("x"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.map(\.role) == [.assistant, .user, .assistant, .tool])
    }

    /// A result the turn above it never asked for sorts to the end rather than
    /// to an arbitrary slot; the orphan repair is what actually removes it.
    @Test
    func anUnmatchedResultSinksToTheEndOfItsBlock() {
        let messages = [
            assistant(calling: ["a", "b"]),
            result("stray"), result("b"), result("a"),
        ]

        let ordered = AgentToolResultOrdering().transform(context(messages)).messages

        #expect(ordered.compactMap(\.toolCallID) == ["a", "b", "stray"])
    }

    @Test
    func onlyTheNewestTurnsResultsSurviveAtFullLength() {
        let long = String(repeating: "x", count: 40_000)
        let messages = [
            assistant(calling: ["old"]),
            result("old", long),
            AgentTranscriptMessage(role: .assistant, text: long),
            assistant(calling: ["new"]),
            result("new", long),
        ]

        let trimmed = AgentToolResultTrimming(limit: 1_000)
            .transform(context(messages)).messages

        #expect(trimmed[1].text.count < 1_200)
        #expect(trimmed[1].text.contains("trimmed from an earlier turn"))
        // The head and the tail both survive: a command output whose ending is
        // missing has lost its error message.
        #expect(trimmed[1].text.hasPrefix("xxxx"))
        #expect(trimmed[1].text.hasSuffix("xxxx"))
        // What the assistant concluded stays whole at any age, and so does the
        // output the model is currently reasoning about.
        #expect(trimmed[2].text.count == 40_000)
        #expect(trimmed[4].text.count == 40_000)
    }

    @Test
    func aResultThatFitsIsNeverAltered() {
        let messages = [assistant(calling: ["a"]), result("a", "short"), .init(role: .user)]
        let trimmed = AgentToolResultTrimming(limit: 1_000)
            .transform(context(messages)).messages
        #expect(trimmed[1].text == "short")
    }

    /// Anchored to the prompt's identity, not to a captured index: the
    /// transforms ahead of it are free to add and remove messages.
    @Test
    func sessionContextLandsDirectlyInFrontOfTheTurnItDescribes() {
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect")
        let block = AgentTranscriptMessage(role: .user, text: "Session context")
        let messages = [
            AgentTranscriptMessage(role: .user, text: "earlier"),
            // An orphan, so the repair ahead of injection changes the count.
            result("gone"),
            prompt,
        ]

        let sent = AgentContextPipeline.chat(sessionContext: block, before: prompt.id)(
            context(messages)
        ).messages

        #expect(sent.map(\.text) == ["earlier", "Session context", "inspect"])
    }

    @Test
    func withoutASessionContextNothingIsInserted() {
        let prompt = AgentTranscriptMessage(role: .user, text: "inspect")
        let sent = AgentContextPipeline.chat(sessionContext: nil, before: prompt.id)(
            context([prompt])
        ).messages
        #expect(sent.map(\.text) == ["inspect"])
    }

    @Test
    func orphanedToolResultsAreDroppedAndAnsweredOnesKept() {
        let messages = [
            assistant(calling: ["kept"]),
            result("kept"),
            result("orphan"),
            // No call id at all: Google addresses a result by name, so absence
            // is not evidence of an orphan.
            AgentTranscriptMessage(role: .tool, text: "ok", toolName: "list_hosts"),
        ]

        let repaired = AgentOrphanedToolResultRepair.apply(messages)

        #expect(repaired.count == 3)
        #expect(!repaired.contains { $0.toolCallID == "orphan" })
    }

    @Test
    func historicalSecretCapabilitiesExpireBeforeAnotherRun() throws {
        let realHandle = UUID().uuidString
        let messages = [
            AgentTranscriptMessage(
                role: .assistant,
                toolCalls: [
                    AgentToolCall(
                        id: "exec", name: "ssh_exec",
                        arguments: .object([
                            "host_id": .string(UUID().uuidString),
                            "command": .string("uptime"),
                            "secret_handle": .string("[REDACTED]"),
                            "stdin_purpose": .null,
                        ])
                    ),
                    AgentToolCall(
                        id: "secret", name: "request_user_secret",
                        arguments: .object(["purpose": .string("sudo")])
                    ),
                ]
            ),
            AgentTranscriptMessage(
                role: .tool,
                text: "<untrusted-data>\n{\"secret_handle\":\"\(realHandle)\"}\n</untrusted-data>",
                toolCallID: "secret", toolName: nil
            ),
        ]

        let sanitized = AgentSecretLifecycle.sanitizeHistoricalMessages(messages)
        let execArguments = try #require(
            sanitized[0].toolCalls[0].arguments.objectValue
        )

        #expect(execArguments["secret_handle"] == nil)
        #expect(execArguments["stdin_purpose"] == .null)
        #expect(sanitized[1].text == AgentSecretLifecycle.expiredResultContent)
        #expect(!sanitized[1].text.contains(realHandle))
    }
}

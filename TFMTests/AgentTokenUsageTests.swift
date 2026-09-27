import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

extension [AgentModelStreamEvent] {
    fileprivate var firstUsage: AgentTokenUsage? {
        for case .usage(let usage) in self { return usage }
        return nil
    }
}

/// Token accounting, from four vendors' spellings through to the split the
/// context gauge shows.
@Suite
struct AgentTokenUsageTests {

    // MARK: - Provider parsing

    @Test
    func responsesReportsUsageWithCachedShare() {
        let events = AgentProviderClient.parseCompletedResponses([
            "object": "response", "status": "completed", "output": [],
            "usage": [
                "input_tokens": 12_000, "output_tokens": 340,
                "input_tokens_details": ["cached_tokens": 9_500],
            ],
        ])

        #expect(events.firstUsage?.inputTokens == 12_000)
        #expect(events.firstUsage?.outputTokens == 340)
        #expect(events.firstUsage?.cachedInputTokens == 9_500)
        // The cached figure is a subset of the prompt total for this vendor, so
        // it must not have been added on top of it.
        #expect(events.firstUsage?.contextTokens == 12_340)
    }

    /// OpenAI sends usage on a final chunk with an empty `choices` array. The
    /// parser used to return early on exactly that shape.
    @Test
    func chatCompletionsReadsUsageFromTheChunkWithNoChoices() {
        let events = AgentProviderClient.parseChat([
            "choices": [[String: Any]](),
            "usage": [
                "prompt_tokens": 8_192, "completion_tokens": 128,
                "prompt_tokens_details": ["cached_tokens": 4_096],
            ],
        ])

        #expect(events.firstUsage?.inputTokens == 8_192)
        #expect(events.firstUsage?.outputTokens == 128)
        #expect(events.firstUsage?.cachedInputTokens == 4_096)
    }

    @Test
    func chatCompletionsStreamingBodyAsksForUsage() throws {
        let client = AgentProviderClient(
            provider: ModelProvider(name: "Compatible", apiFormat: .chatCompletions),
            model: AIModel(id: "gpt-5"),
            secret: "key"
        )
        let request = AgentModelRequest(
            systemPrompt: "system", messages: [], tools: []
        )

        let streaming = client.body(request, streaming: true)
        let options = try #require(streaming["stream_options"] as? [String: Any])
        #expect(options["include_usage"] as? Bool == true)

        // Not on the buffered path: several OpenAI-compatible gateways reject
        // the key outright when `stream` is false.
        #expect(client.body(request, streaming: false)["stream_options"] == nil)
    }

    /// The one vendor whose `input_tokens` is not the prompt total. With prompt
    /// caching working, taking it at face value reads near-empty on a context
    /// that is nearly full.
    @Test
    func anthropicAddsCacheTokensIntoTheInputTotal() {
        let events = AgentProviderClient.parseAnthropic(
            "message_start",
            [
                "message": [
                    "usage": [
                        "input_tokens": 220,
                        "cache_read_input_tokens": 96_000,
                        "cache_creation_input_tokens": 1_800,
                    ]
                ]
            ])

        #expect(events.firstUsage?.inputTokens == 98_020)
        #expect(events.firstUsage?.cachedInputTokens == 96_000)
    }

    @Test
    func anthropicReportsOutputOnMessageDelta() {
        let events = AgentProviderClient.parseAnthropic(
            "message_delta", ["usage": ["output_tokens": 512]]
        )

        #expect(events.firstUsage?.outputTokens == 512)
    }

    @Test
    func googleReadsUsageFromAChunkWithNoCandidates() {
        let events = AgentProviderClient.parseGoogle([
            "usageMetadata": [
                "promptTokenCount": 4_400, "candidatesTokenCount": 210,
                "cachedContentTokenCount": 2_048,
            ]
        ])

        #expect(events.firstUsage?.inputTokens == 4_400)
        #expect(events.firstUsage?.outputTokens == 210)
        #expect(events.firstUsage?.cachedInputTokens == 2_048)
    }

    /// A gateway is free to send `1024.0`, and reading these as `Int` directly
    /// returns nil for that.
    @Test
    func usageSurvivesFloatingPointCounts() {
        let events = AgentProviderClient.parseChat([
            "choices": [[String: Any]](),
            "usage": ["prompt_tokens": 1024.0, "completion_tokens": 16.0],
        ])

        #expect(events.firstUsage?.inputTokens == 1_024)
        #expect(events.firstUsage?.outputTokens == 16)
    }

    // MARK: - Merging

    /// Anthropic and Gemini both report cumulatively across several events of
    /// one turn. Summing would multiply the count by the number of chunks.
    @Test
    func mergingTakesTheHighestOfEachFieldRatherThanSumming() {
        let start = AgentTokenUsage(inputTokens: 98_020, cachedInputTokens: 96_000)
        let firstDelta = start.merging(AgentTokenUsage(outputTokens: 120))
        let secondDelta = firstDelta.merging(AgentTokenUsage(outputTokens: 512))

        #expect(secondDelta.inputTokens == 98_020)
        #expect(secondDelta.cachedInputTokens == 96_000)
        #expect(secondDelta.outputTokens == 512)
    }

    @Test
    func emptyUsageIsDistinguishableFromAZeroCostTurn() {
        #expect(AgentTokenUsage().isEmpty)
        #expect(!AgentTokenUsage(inputTokens: 1).isEmpty)
    }

    // MARK: - Estimate

    @Test
    func estimateSeparatesToolResultsFromTheConversation() {
        let estimate = AgentContextEstimator.estimate(
            systemPrompt: String(repeating: "s", count: 400),
            toolSchemaCharacters: 800,
            transcript: [
                AgentTranscriptMessage(role: .user, text: String(repeating: "u", count: 400)),
                AgentTranscriptMessage(
                    role: .tool, text: String(repeating: "t", count: 4_000),
                    toolCallID: "call-1", toolName: "ssh_exec"
                ),
            ],
            attachedCharacters: 200,
            measured: nil
        )

        #expect(estimate.tokens(.systemPrompt) == 100)
        #expect(estimate.tokens(.tools) == 200)
        #expect(estimate.tokens(.conversation) == 100)
        #expect(estimate.tokens(.toolResults) == 1_000)
        #expect(estimate.tokens(.attachments) == 50)
        #expect(estimate.total == 1_450)
        #expect(!estimate.isMeasured)
    }

    /// The breakdown sits directly under the total it belongs to. Two numbers on
    /// one screen that disagree leave the reader no way to tell which is wrong.
    @Test
    func measuredTotalRescalesThePartsToSumExactly() {
        let estimate = AgentContextEstimator.estimate(
            systemPrompt: String(repeating: "s", count: 400),
            toolSchemaCharacters: 800,
            transcript: [
                AgentTranscriptMessage(role: .user, text: String(repeating: "u", count: 4_000))
            ],
            attachedCharacters: 0,
            measured: AgentTokenUsage(inputTokens: 3_000, outputTokens: 500)
        )

        #expect(estimate.isMeasured)
        #expect(estimate.total == 3_500)
        #expect(estimate.parts.values.reduce(0, +) == 3_500)
        // Proportions survive: the conversation was ~77% of the estimate.
        #expect(estimate.tokens(.conversation) > estimate.tokens(.tools))
    }

    @Test
    func shareIsNilWithoutAKnownContextWindow() {
        let estimate = AgentContextEstimator.estimate(
            systemPrompt: "s", toolSchemaCharacters: 0, transcript: [],
            attachedCharacters: 0, measured: nil
        )

        #expect(estimate.share(of: nil) == nil)
        #expect(estimate.share(of: 0) == nil)
    }

    @Test
    func shareIsClampedSoAnOverfullContextCannotDrawPastTheRing() {
        let estimate = AgentContextEstimator.estimate(
            systemPrompt: "", toolSchemaCharacters: 0, transcript: [],
            attachedCharacters: 0,
            measured: AgentTokenUsage(inputTokens: 300_000)
        )

        #expect(estimate.share(of: 200_000) == 1)
    }

    @Test
    func aChipAndTheGaugeAgreeOnWhatAnAttachmentCosts() {
        let content = String(repeating: "x", count: 4_000)
        let chip = ContextChip(kind: .output, label: "Last 200 lines", content: content)

        #expect(chip.approximateTokens == AgentContextEstimator.tokens(inCharacters: 4_000))
    }

    @Test
    func incrementalTrackerMatchesTheReferenceEstimator() {
        let user = AgentTranscriptMessage(
            role: .user, text: String(repeating: "u", count: 400)
        )
        let tool = AgentTranscriptMessage(
            role: .tool, text: String(repeating: "t", count: 4_000),
            toolCallID: "call", toolName: "lookup"
        )
        let tracker = AgentContextEstimateTracker(
            systemPrompt: AgentSystemPrompt.default,
            toolSchemaCharacters: 800,
            transcript: [user],
            attachedCharacters: 200,
            measured: nil
        )

        tracker.appendStreamingText(String(repeating: "a", count: 120), to: tool.id)
        #expect(tracker.snapshot().tokens(.conversation) > 0)
        tracker.upsert(tool)

        let reference = AgentContextEstimator.estimate(
            systemPrompt: AgentSystemPrompt.default,
            toolSchemaCharacters: 800,
            transcript: [user, tool],
            attachedCharacters: 200,
            measured: nil
        )
        #expect(tracker.snapshot() == reference)

        let measured = AgentTokenUsage(inputTokens: 3_000, outputTokens: 500)
        tracker.setMeasured(measured)
        let measuredReference = AgentContextEstimator.estimate(
            systemPrompt: AgentSystemPrompt.default,
            toolSchemaCharacters: 800,
            transcript: [user, tool],
            attachedCharacters: 200,
            measured: measured
        )
        #expect(tracker.snapshot() == measuredReference)

        tracker.remove([tool.id])
        tracker.setMeasured(nil)
        #expect(
            tracker.snapshot()
                == AgentContextEstimator.estimate(
                    systemPrompt: AgentSystemPrompt.default,
                    toolSchemaCharacters: 800,
                    transcript: [user],
                    attachedCharacters: 200,
                    measured: nil
                )
        )
    }

    @Test
    func composerDraftEditsNeverRebuildTheContextEstimate() {
        let transcript = (0..<300).map { index in
            AgentTranscriptMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: String(repeating: "message \(index) ", count: 80)
            )
        }
        let conversation = ConversationModel(transcript: transcript)
        let rebuilds = conversation.contextEstimateFullRebuildCount
        let estimate = conversation.contextEstimate

        for revision in 0..<100 {
            conversation.composer.draft = "draft \(revision)"
            _ = conversation.contextEstimate
        }

        #expect(conversation.contextEstimateFullRebuildCount == rebuilds)
        #expect(conversation.contextEstimate == estimate)
    }

    @Test
    func conversationSnapshotTracksAttachmentsHistoryEditsAndUsage() throws {
        let conversation = ConversationModel()
        conversation.attach(
            ContextChip(
                kind: .output, label: "diagnostic",
                content: String(repeating: "a", count: 400)
            )
        )
        expectSnapshotMatchesReference(conversation)

        let opening = conversation.appendUserTurnContent("inspect")
        let assistant = AgentTranscriptMessage(role: .assistant, text: "answer")
        conversation.handle(.messageFinished(assistant))
        expectSnapshotMatchesReference(conversation)

        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call", name: "lookup", arguments: .object([:]))
        )
        conversation.handle(
            .toolFinished(
                invocation,
                AgentToolResult(callID: "call", content: String(repeating: "r", count: 800))
            ))
        expectSnapshotMatchesReference(conversation)

        #expect(conversation.editUserMessage(opening.id, authoredText: "edited") == nil)
        expectSnapshotMatchesReference(conversation)

        let followUp = conversation.appendUserTurnContent("Explain the result")
        conversation.handle(.messageFinished(AgentTranscriptMessage(role: .assistant, text: "explanation")))
        _ = try #require(conversation.editUserMessage(followUp.id, authoredText: "edited"))
        expectSnapshotMatchesReference(conversation)

        conversation.applyCompaction(summary: "summary", cut: 1)
        expectSnapshotMatchesReference(conversation)

        conversation.handle(.usageUpdated(AgentTokenUsage(inputTokens: 2_000, outputTokens: 80)))
        expectSnapshotMatchesReference(conversation)

        let forkSource = ConversationModel()
        forkSource.appendUserTurn("question")
        let forkAnswer = AgentTranscriptMessage(role: .assistant, text: "answer")
        forkSource.handle(.messageFinished(forkAnswer))
        let fork = try #require(forkSource.forked(throughAssistantMessage: forkAnswer.id))
        expectSnapshotMatchesReference(fork)
    }

    private func expectSnapshotMatchesReference(_ conversation: ConversationModel) {
        let attachedCharacters = conversation.composer.attachments.reduce(0) {
            $0
                + ($1.image == nil
                    ? AgentContextEstimator.characterUnits(in: $1.content)
                    : $1.approximateTokens * AgentContextEstimator.charactersPerToken)
        }
        #expect(
            conversation.contextEstimate
                == AgentContextEstimator.estimate(
                    systemPrompt: TermindAgentPolicy.systemPrompt,
                    toolSchemaCharacters: conversation.toolSchemaCharacters,
                    transcript: conversation.transcript,
                    attachedCharacters: attachedCharacters,
                    measured: conversation.usage
                )
        )
    }
}

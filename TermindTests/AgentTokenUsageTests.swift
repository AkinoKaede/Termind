import Foundation
import Testing

@testable import Termind

private extension [AgentModelStreamEvent] {
    var firstUsage: AgentTokenUsage? {
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
            provider: ModelProvider(name: "Compatible", kind: .openAI),
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
        let events = AgentProviderClient.parseAnthropic("message_start", [
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
}

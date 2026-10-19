import AgentKit
import Foundation
import TermindApplication
import TermindDomain
import Testing

@Suite
struct AgentTokenUsageTests {

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

        #expect(conversation.editUserMessage(opening.id, authoredText: "edited") != nil)
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

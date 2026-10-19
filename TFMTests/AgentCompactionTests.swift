import AgentKit
import Foundation
import TermindApplication
import Testing

/// Roughly `tokens * 4` characters, so a budget can be reasoned about in a test
/// the same way the estimator computes it. Shared with `WindowStateTests`,
/// which sizes its compaction fixture against the same budget.
func filler(tokens: Int) -> String {
    String(repeating: "x", count: tokens * AgentContextEstimator.charactersPerToken)
}

@Suite
struct AgentCompactionTests {

    // MARK: - Applying it

    @Test
    func applyingReplacesWhatIsSentAndKeepsWhatIsShown() throws {
        let conversation = ConversationModel()
        for index in 0..<6 {
            conversation.appendUserTurn("turn \(index) \(filler(tokens: 300))")
        }
        let visibleBefore = conversation.messages.count
        let span = try #require(conversation.compactionSpan(keepRecentTokens: 600))

        conversation.applyCompaction(summary: "## Goal\nFix the disk", cut: span.cut)

        // What is sent shrank.
        #expect(conversation.transcript.count == 1 + (visibleBefore - span.cut))
        #expect(conversation.transcript.first?.isCompaction == true)
        #expect(conversation.transcript.first?.text.contains("Fix the disk") == true)
        // What is shown did not. Compaction shapes the request, never history.
        #expect(conversation.messages.count == visibleBefore)
        #expect(conversation.compactions.count == 1)
    }

    @Test
    func preparingACompactionDoesNotMutateTheConversation() throws {
        let conversation = ConversationModel()
        for index in 0..<4 {
            conversation.appendUserTurn("turn \(index) " + filler(tokens: 300))
        }
        let span = try #require(conversation.compactionSpan(keepRecentTokens: 300))
        let transcript = conversation.transcript
        let estimate = conversation.contextEstimate

        let record = try #require(
            conversation.prepareCompaction(
                summary: "summary", cut: span.cut
            ))

        #expect(conversation.transcript == transcript)
        #expect(conversation.contextEstimate == estimate)
        #expect(conversation.compactions.isEmpty)
        #expect(record.compactedThroughMessageID == transcript[span.cut - 1].id)
    }

    @Test
    func aRepeatedCompactionInheritsTheRawBoundaryWhenItOnlyFoldsTheOldSummary() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("old " + filler(tokens: 600))
        conversation.appendUserTurn("recent " + filler(tokens: 20))
        let firstSpan = try #require(conversation.compactionSpan(keepRecentTokens: 20))
        let first = try #require(
            conversation.applyCompaction(
                summary: "first summary", cut: firstSpan.cut
            ))

        let second = try #require(
            conversation.prepareCompaction(
                summary: "second summary", cut: 1
            ))

        #expect(second.compactedThroughMessageID == first.compactedThroughMessageID)
        #expect(second.sequence == first.sequence + 1)
    }

    @Test
    func compactionActivityIsEphemeralAndNeverBecomesAMessage() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("old " + filler(tokens: 800))
        conversation.appendUserTurn("recent " + filler(tokens: 20))
        let messageCount = conversation.messages.count

        conversation.beginCompaction()
        #expect(conversation.isCompacting)
        #expect(
            conversation.timeline.contains {
                if case .compactionActivity(let activity) = $0,
                    case .running = activity.state
                {
                    return true
                }
                return false
            })

        let span = try #require(conversation.compactionSpan(keepRecentTokens: 20))
        conversation.applyCompaction(summary: "summary", cut: span.cut)
        conversation.endCompaction()

        #expect(!conversation.isCompacting)
        #expect(conversation.compactionActivity == nil)
        #expect(conversation.messages.count == messageCount)
        #expect(conversation.compactions.count == 1)
    }

    @Test
    func failedCompactionKeepsAUiResultWithoutWritingAssistantHistory() {
        let conversation = ConversationModel()
        conversation.beginCompaction()
        conversation.failCompaction("There is not enough history to compact yet.")

        #expect(!conversation.isCompacting)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.transcript.isEmpty)
        #expect(!conversation.isEmpty)
        guard case .failed(let reason)? = conversation.compactionActivity?.state else {
            Issue.record("Expected a failed compaction activity")
            return
        }
        #expect(reason == "There is not enough history to compact yet.")
    }

    /// The marker sorts above the history it kept rather than to the end of the
    /// conversation, so the line reads as a boundary and not as a footnote.
    @Test
    func theMarkerSortsWhereTheCutHappened() throws {
        let conversation = ConversationModel()
        for index in 0..<6 {
            conversation.appendUserTurn("turn \(index) \(filler(tokens: 300))")
        }
        let span = try #require(conversation.compactionSpan(keepRecentTokens: 600))
        conversation.applyCompaction(summary: "summary", cut: span.cut)

        let markIndex = try #require(
            conversation.timeline.firstIndex { if case .compaction = $0 { true } else { false } }
        )
        #expect(markIndex > 0)
        #expect(markIndex < conversation.timeline.count - 1)
    }

}

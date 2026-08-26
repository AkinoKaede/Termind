import Foundation
import Testing

@testable import Termind

/// A run that never ends on its own, so a conversation stays steerable for as
/// long as a test needs it to be.
private struct HangingAgentModel: AgentModelStreaming {
    func stream(
        _ request: AgentModelRequest
    ) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.textDelta("working"))
                try? await Task.sleep(for: .seconds(30))
                continuation.finish()
            }
        }
    }
}

/// What the conversation does with a message typed at a working agent.
///
/// The runtime's half of steering is covered in `AgentRuntimeTests`; this is the
/// half the user sees — that the words leave the composer without pretending to
/// be a turn, that they become one at the moment the run actually takes them,
/// and that a run which ends first gives them back instead of eating them.
@MainActor
@Suite
struct AgentSteeringTests {

    @Test
    func aQueuedDraftLeavesTheComposerWithoutEnteringEitherTranscript() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.attach(ContextChip(kind: .output, label: "Last 20 lines", content: "boom"))
        conversation.draft = "  also tail the error log  "

        conversation.submitSteeringDraft()

        #expect(conversation.draft.isEmpty)
        // Consumed by the message they were attached to, exactly as a turn that
        // starts a run consumes them.
        #expect(conversation.attachments.isEmpty)
        #expect(conversation.messages.isEmpty)
        #expect(conversation.transcript.isEmpty)

        #expect(conversation.pendingSteering.count == 1)
        let pending = conversation.pendingSteering[0]
        #expect(pending.draft == "also tail the error log")
        #expect(pending.attachments.count == 1)
        // The payload travels with it. A chip that only labelled something
        // would disclose nothing to the model.
        #expect(pending.message.text.contains("<output label=\"Last 20 lines\">"))
        #expect(pending.message.text.contains("boom"))
    }

    @Test
    func deliveryMovesAQueuedMessageIntoBothTranscripts() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.draft = "check nginx too"
        conversation.submitSteeringDraft()
        let queued = try! #require(conversation.pendingSteering.first).message

        // Restamped by the run, which is what puts the bubble after the reply
        // the user was reading when they typed it rather than before it.
        var delivered = queued
        delivered.createdAt = .now
        conversation.handle(.steeringDelivered(delivered))

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.messages.count == 1)
        #expect(conversation.messages[0].role == .user)
        #expect(conversation.messages[0].id == queued.id)
        #expect(conversation.messages[0].text == "check nginx too")
        #expect(conversation.messages[0].createdAt == delivered.createdAt)
        #expect(conversation.transcript == [delivered])
    }

    @Test
    func stoppingARunHandsUndeliveredWordsBackToTheComposer() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.attach(ContextChip(kind: .file, label: "nginx.conf", content: "server {}"))
        conversation.draft = "first"
        conversation.submitSteeringDraft()
        conversation.draft = "second"
        conversation.submitSteeringDraft()
        conversation.draft = "third, still being typed"

        conversation.stop()

        #expect(conversation.pendingSteering.isEmpty)
        // In the order they were typed, with whatever was still in the box
        // last, so nothing has to be reassembled by hand.
        #expect(conversation.draft == "first\n\nsecond\n\nthird, still being typed")
        // The composer gets the draft back, not the folded payload.
        #expect(!conversation.draft.contains("<file"))
        #expect(conversation.attachments.count == 1)
        #expect(conversation.attachments[0].label == "nginx.conf")
    }

    @Test
    func aRunThatFailsReturnsTheQueueAsWell() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.draft = "and restart it"
        conversation.submitSteeringDraft()

        conversation.handle(.runState(.failed))

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.draft == "and restart it")
    }

    @Test
    func takingOneRowBackLeavesTheRestQueued() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.draft = "first"
        conversation.submitSteeringDraft()
        conversation.draft = "second"
        conversation.submitSteeringDraft()

        conversation.returnSteeringToDraft(conversation.pendingSteering[0].id)

        #expect(conversation.draft == "first")
        #expect(conversation.pendingSteering.count == 1)
        #expect(conversation.pendingSteering[0].draft == "second")
    }

    @Test
    func anEmptyDraftQueuesNothing() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.draft = "   \n "

        conversation.submitSteeringDraft()

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.draft == "   \n ")
    }

    /// Nothing is queued without a run to hand it to — an idle composer sends.
    @Test
    func thereIsNothingToSteerWithoutARun() {
        let conversation = ConversationModel()
        conversation.draft = "hello"

        conversation.submitSteeringDraft()

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.draft == "hello")
    }

    /// A background command finishing is addressed to the model, which asked
    /// for it. It is not addressed to the user, and the transcript has only
    /// three roles — so a visible version would be a bubble attributed to
    /// someone who never said it.
    @Test
    func aNoticeReachesTheModelWithoutAppearingInTheConversation() {
        let conversation = ConversationModel()
        let notice = AgentTranscriptMessage(
            role: .user, text: "The background command `deploy.sh` has finished."
        )

        conversation.handle(.noticeDelivered(notice))

        #expect(conversation.transcript == [notice])
        #expect(conversation.messages.isEmpty)
        #expect(conversation.timeline.isEmpty)
    }

    private func startRun(_ conversation: ConversationModel) {
        conversation.start(
            runtime: AgentRuntime(
                model: HangingAgentModel(), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "start",
                permissionMode: .askForApproval
            )
        )
    }
}

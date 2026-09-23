import AgentKit
import Foundation
import TermindDomain
import TermindInfrastructure
import Testing

@testable import TermindApplication

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
        conversation.composer.draft = "  also tail the error log  "

        conversation.submitSteeringDraft()

        #expect(conversation.composer.draft.isEmpty)
        // Consumed by the message they were attached to, exactly as a turn that
        // starts a run consumes them.
        #expect(conversation.composer.attachments.isEmpty)
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
        conversation.attach(
            ContextChip(kind: .pastedText, label: "Pasted text", content: "large context")
        )
        conversation.composer.draft = "check nginx too"
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
        #expect(conversation.messages[0].contextChips.map(\.label) == ["Pasted text"])
        #expect(!conversation.messages[0].text.contains("large context"))
        #expect(delivered.text.contains("large context"))
        #expect(conversation.messages[0].createdAt == delivered.createdAt)
        #expect(conversation.transcript == [delivered])
    }

    @Test
    func stoppingARunHandsUndeliveredWordsBackToTheComposer() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.attach(ContextChip(kind: .file, label: "nginx.conf", content: "server {}"))
        conversation.composer.draft = "first"
        conversation.submitSteeringDraft()
        conversation.composer.draft = "second"
        conversation.submitSteeringDraft()
        conversation.composer.draft = "third, still being typed"

        conversation.stop()

        #expect(conversation.pendingSteering.isEmpty)
        // In the order they were typed, with whatever was still in the box
        // last, so nothing has to be reassembled by hand.
        #expect(conversation.composer.draft == "first\n\nsecond\n\nthird, still being typed")
        // The composer gets the draft back, not the folded payload.
        #expect(!conversation.composer.draft.contains("<file"))
        #expect(conversation.composer.attachments.count == 1)
        #expect(conversation.composer.attachments[0].label == "nginx.conf")
    }

    @Test
    func aRunThatFailsReturnsTheQueueAsWell() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.composer.draft = "and restart it"
        conversation.submitSteeringDraft()

        conversation.handle(.runState(.failed))

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.composer.draft == "and restart it")
    }

    @Test
    func takingOneRowBackLeavesTheRestQueued() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.composer.draft = "first"
        conversation.submitSteeringDraft()
        conversation.composer.draft = "second"
        conversation.submitSteeringDraft()

        conversation.returnSteeringToDraft(conversation.pendingSteering[0].id)

        #expect(conversation.composer.draft == "first")
        #expect(conversation.pendingSteering.count == 1)
        #expect(conversation.pendingSteering[0].draft == "second")
    }

    @Test
    func anEmptyDraftQueuesNothing() {
        let conversation = ConversationModel()
        startRun(conversation)
        conversation.composer.draft = "   \n "

        conversation.submitSteeringDraft()

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.composer.draft == "   \n ")
    }

    @Test
    func anImageOnlySteeringMessageQueuesAndRestoresItsAttachment() throws {
        let conversation = ConversationModel()
        startRun(conversation)
        let image = AgentImageAttachment(
            label: "graph.png", mimeType: "image/png", data: Data([7, 8, 9]),
            pixelWidth: 20, pixelHeight: 20
        )
        conversation.attach(ContextChip(kind: .image, label: image.label, image: image))

        conversation.submitSteeringDraft()

        let pending = try #require(conversation.pendingSteering.first)
        #expect(pending.draft.isEmpty)
        #expect(pending.message.text.isEmpty)
        #expect(pending.message.images == [image])
        #expect(conversation.composer.attachments.isEmpty)

        conversation.stop()
        #expect(conversation.composer.attachments.first?.image == image)
    }

    /// Nothing is queued without a run to hand it to — an idle composer sends.
    @Test
    func thereIsNothingToSteerWithoutARun() {
        let conversation = ConversationModel()
        conversation.composer.draft = "hello"

        conversation.submitSteeringDraft()

        #expect(conversation.pendingSteering.isEmpty)
        #expect(conversation.composer.draft == "hello")
    }

    @Test
    func steeringCapturesTheSendingTerminalAndDoesNotChangeTheRunningContextUntilDelivery() {
        let conversation = ConversationModel()
        let memorySessionID = UUID()
        let first = AgentTurnContextSnapshot(
            sessionContext: "host A", skillCatalog: "fixed skills", planContract: "fixed mode",
            toolAvailability: ["terminal_suggest": false, "future_surface_tool": false],
            memorySessionID: memorySessionID)
        let repository = InMemoryAgentRunRepository()
        conversation.start(
            runtime: AgentRuntime(
                model: HangingAgentModel(), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "start", permissionMode: .askForApproval,
                contextSnapshot: first),
            repository: repository)
        conversation.composer.draft = "inspect here"
        conversation.submitSteeringDraft(
            context: SessionContext(hostName: "B", workingDirectory: "/srv"),
            terminalSuggestionsAvailable: true)
        let queued = try! #require(conversation.pendingSteering.first?.message)
        #expect(conversation.activeContextSnapshot == first)
        #expect(queued.contextSnapshot?.sessionContext?.contains("host_name: B") == true)
        #expect(queued.contextSnapshot?.skillCatalog == first.skillCatalog)
        #expect(queued.contextSnapshot?.planContract == first.planContract)
        #expect(queued.contextSnapshot?.memorySessionID == memorySessionID)
        #expect(queued.contextSnapshot?.toolAvailability?["terminal_suggest"] == true)
        #expect(queued.contextSnapshot?.toolAvailability?["future_surface_tool"] == false)
        conversation.handle(.steeringDelivered(queued))
        #expect(conversation.activeContextSnapshot == queued.contextSnapshot)
        #expect(conversation.transcript.last?.text == "inspect here")
        conversation.stop()
    }

    @Test
    func steeringKeepsLegacyUnknownContextUnknown() {
        let conversation = ConversationModel()
        startRun(conversation)
        #expect(conversation.activeContextSnapshot == nil)
        conversation.composer.draft = "inspect here"

        conversation.submitSteeringDraft(terminalSuggestionsAvailable: true)

        #expect(conversation.pendingSteering.first?.message.contextSnapshot == nil)
        conversation.stop()
    }

    private func startRun(_ conversation: ConversationModel) {
        let repository = InMemoryAgentRunRepository()
        conversation.start(
            runtime: AgentRuntime(
                model: HangingAgentModel(), tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "start",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
    }
}

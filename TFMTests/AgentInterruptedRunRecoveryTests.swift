import AgentKit
import Foundation
import SwiftData
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPersistence
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind

/// What a force quit during a tool batch leaves behind, and what it takes to
/// make that conversation usable again.
///
/// The failure it guards is total, not partial: an assistant turn carrying a
/// tool call that nothing answers is rejected outright by every provider —
/// OpenAI says `No tool output found for function call call_…` — so the
/// conversation cannot be continued at all, only deleted.
@Suite
struct AgentInterruptedRunRecoveryTests {
    private func assistant(calling ids: [String]) -> AgentTranscriptMessage {
        AgentTranscriptMessage(
            role: .assistant, text: "Checking both.",
            toolCalls: ids.map { AgentToolCall(id: $0, name: "ssh_exec", arguments: .object([:])) }
        )
    }

    private func answer(_ id: String, _ text: String) -> AgentTranscriptMessage {
        AgentTranscriptMessage(role: .tool, text: text, toolCallID: id, toolName: "ssh_exec")
    }

    @Test
    func everyToolCallEndsUpAnsweredAtTheModelBoundary() {
        let messages = [
            AgentTranscriptMessage(role: .user, text: "check both hosts"),
            assistant(calling: ["call-a", "call-b"]),
            answer("call-a", "up 3 days"),
        ]

        let sent = AgentContextPipeline.chat(sessionContext: nil, before: nil)(
            AgentModelContext(systemPrompt: "s", messages: messages, tools: [])
        ).messages

        let answered = Set(sent.compactMap(\.toolCallID))
        #expect(answered == ["call-a", "call-b"])
        // Placed against the call it answers, not appended to the end.
        #expect(sent.map(\.role) == [.user, .assistant, .tool, .tool])
        // The recovered output is untouched; only the missing one is invented.
        #expect(sent[2].text == "up 3 days")
        #expect(sent[3].isError)
    }

    /// It must not claim the action did not happen. The process died after the
    /// command was sent, so whether the remote side ran it is genuinely
    /// unknown, and a model told "this never ran" will cheerfully run it again.
    @Test
    func theSynthesizedAnswerDoesNotClaimTheToolNeverRan() {
        let repaired = AgentUnansweredToolCallRepair.apply([assistant(calling: ["call-a"])])

        let text = try! #require(repaired.last?.text)
        #expect(text.contains("unknown"))
        #expect(!text.lowercased().contains("never ran"))
    }

    @Test
    func repairingIsIdempotentAndLeavesCompleteTurnsAlone() {
        let messages = [assistant(calling: ["call-a"]), answer("call-a", "ok")]

        let once = AgentUnansweredToolCallRepair.apply(messages)
        #expect(once == messages)
        #expect(AgentUnansweredToolCallRepair.apply(once) == once)
    }

    /// Results are recorded as each tool finishes, but their transcript rows are
    /// only written when the run next saves its snapshot. A process killed in
    /// between leaves the call answered in storage and unanswered in history —
    /// so restore should hand back the real output, not a placeholder for it.
    @MainActor
    @Test
    func restoreRecoversResultsRecordedBeforeTheProcessDied() async throws {
        let configuration = localModelConfiguration(
            "AgentInterruptedRunRecoveryTests", schema: HostPersistence.schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: HostPersistence.schema, configurations: [configuration]
        )
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)

        // The snapshot as it stood when the assistant turn was persisted: two
        // calls, no results yet.
        let snapshot = AgentRunSnapshot(
            conversationID: UUID(), state: .running, permissionMode: .askForApproval,
            messages: [
                AgentTranscriptMessage(role: .user, text: "check both hosts"),
                assistant(calling: ["call-a", "call-b"]),
            ]
        )
        try await repository.save(snapshot)

        // One tool finished and was recorded; the other was still running when
        // the app was killed, so no snapshot save ever followed.
        let finished = AgentToolInvocation(
            runID: snapshot.id,
            call: AgentToolCall(id: "call-a", name: "ssh_exec", arguments: .object([:]))
        )
        try await repository.record(.toolStarted(finished), runID: snapshot.id)
        try await repository.record(
            .toolFinished(finished, AgentToolResult(callID: "call-a", content: "up 3 days")),
            runID: snapshot.id
        )
        let running = AgentToolInvocation(
            runID: snapshot.id,
            call: AgentToolCall(id: "call-b", name: "ssh_exec", arguments: .object([:]))
        )
        try await repository.record(.toolStarted(running), runID: snapshot.id)

        // Relaunch.
        let reopened = SwiftDataAgentRunRepository(context: container.mainContext)
        let restored = try #require(try await reopened.loadConversations().first)

        let recovered = try #require(restored.messages.first { $0.toolCallID == "call-a" })
        #expect(recovered.text == "up 3 days", "the recorded output should come back")
        #expect(!recovered.isError)
        #expect(restored.lastRunState == .interrupted)

        // The one that never finished is still unanswered here — storage has
        // nothing to recover — and is repaired at the model boundary.
        let sent = AgentContextPipeline.chat(sessionContext: nil, before: nil)(
            AgentModelContext(systemPrompt: "s", messages: restored.messages, tools: [])
        ).messages
        #expect(Set(sent.compactMap(\.toolCallID)) == ["call-a", "call-b"])
    }

    /// A card left mid-flight by a force quit must not come back spinning.
    /// Every run is marked interrupted at launch, so `running` is never a state
    /// a restored card can legitimately be in.
    @MainActor
    @Test
    func restoredCardsDoNotComeBackRunning() {
        let store = AssistantConversationStore()
        let invocation = AgentToolInvocation(
            runID: UUID(),
            call: AgentToolCall(id: "call-b", name: "ssh_exec", arguments: .object([:]))
        )
        store.restore([
            StoredAgentConversation(
                id: UUID(),
                messages: [],
                toolCards: [
                    StoredAgentToolCard(
                        invocation: invocation,
                        descriptor: AgentToolDescriptor(
                            name: "ssh_exec", summary: "exec", inputSchema: .object([:]),
                            target: .host, approvalPolicy: .ask
                        ),
                        state: "started", result: nil
                    )
                ],
                lastRunState: .interrupted
            )
        ])

        let card = try! #require(store.conversations.first?.toolCards.first)
        #expect(card.state == .interrupted)
    }
}

import AgentKit
import Foundation
import TermindApplication
import TermindPresentation
import Testing

@MainActor
@Suite
struct AssistantTranscriptPresentationTests {
    @Test func toolBatchAndFirstToolWithTheSameSourceIDHaveIndependentDisclosures() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()
        let batch = AssistantTranscriptDisclosureID.toolBatch(id)
        let tool = AssistantTranscriptDisclosureID.tool(id)

        #expect(!state.isExpanded(batch))
        #expect(!state.isExpanded(tool))

        state.toggleDisclosure(batch)
        #expect(state.isExpanded(batch))
        #expect(!state.isExpanded(tool))

        state.toggleDisclosure(tool)
        #expect(state.isExpanded(batch))
        #expect(state.isExpanded(tool))

        state.toggleDisclosure(tool)
        #expect(state.isExpanded(batch))
        #expect(!state.isExpanded(tool))

        state.toggleDisclosure(batch)
        state.toggleDisclosure(batch)
        #expect(state.isExpanded(batch))
        #expect(!state.isExpanded(tool))
        #expect(state.layoutRevision(for: [id]) > 0)
    }

    @Test func aSingleToolDefaultsClosedWithoutBecomingStoredBatchState() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()

        #expect(!state.isExpanded(.tool(id)))
        #expect(!state.isExpanded(.toolBatch(id)))

        state.toggleDisclosure(.tool(id))
        #expect(state.isExpanded(.tool(id)))
        #expect(!state.isExpanded(.toolBatch(id)))
    }

    @Test func changingFromOneToolToABatchUsesBatchDefaultsAndKeepsExplicitToolChoices() {
        let id = UUID()
        let untouched = AssistantTranscriptPresentationState()

        #expect(!untouched.isExpanded(.tool(id)))
        #expect(!untouched.isExpanded(.toolBatch(id)))

        let explicitlyExpanded = AssistantTranscriptPresentationState()
        explicitlyExpanded.toggleDisclosure(.tool(id))
        #expect(explicitlyExpanded.isExpanded(.tool(id)))
        #expect(!explicitlyExpanded.isExpanded(.toolBatch(id)))
    }

    @Test func completionKeepsVisibleWorkAndPruningDropsOldConversationState() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()
        let old = work(id: id, state: .running)
        let completed = work(id: id, state: .completed)
        state.prepareWorkCompletionTransitions(from: [old], to: [completed], visibleIDs: [id])
        #expect(state.isExpanded(.work(id)))
        #expect(state.collapseWorkOutsideViewport(visibleIDs: [id]).isEmpty)
        #expect(state.collapseWorkOutsideViewport(visibleIDs: []) == [id])
        #expect(!state.isExpanded(.work(id)))

        state.toggleDisclosure(.work(id))
        state.prune(validTimelineIDs: [])
        #expect(!state.readerDidToggle(.work(id)))
        #expect(state.layoutRevision(for: [id]) == 0)
    }

    @Test func historicalAndManuallyFoldedWorkDoNotAcquirePendingCollapses() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()
        let old = work(id: id, state: .running)
        let completed = work(id: id, state: .completed)
        state.prepareWorkCompletionTransitions(from: [], to: [completed], visibleIDs: [id])
        #expect(!state.isExpanded(.work(id)))
        state.toggleDisclosure(.work(id), default: true)
        state.prepareWorkCompletionTransitions(from: [old], to: [completed], visibleIDs: [id])
        #expect(!state.isExpanded(.work(id)))
        #expect(!state.hasPendingAutoCollapse(id))
        let afterAnswer = work(id: id, state: .completed, afterAnswer: true)
        let fresh = AssistantTranscriptPresentationState()
        fresh.prepareWorkCompletionTransitions(from: [old], to: [afterAnswer], visibleIDs: [])
        #expect(fresh.isExpanded(.work(id), default: true))
    }

    @Test func durationFloorsSecondsAndDoesNotDependOnTheRenderingClock() {
        let start = Date(timeIntervalSince1970: 10_000)
        let locale = Locale(identifier: "en")
        for (elapsed, expected) in [(59.99, "59s"), (60.0, "1m"), (61.9, "1m 1s"), (3_600.0, "1h"), (-1.0, "0s")] {
            #expect(
                AgentWorkPresentation.duration(from: start, to: start.addingTimeInterval(elapsed), locale: locale)
                    == expected)
        }
        #expect(!AgentWorkPresentation.isExpandedByDefault(for: .completed))
        for state: AgentRunState in [.running, .waitingForUser, .waitingForApproval, .failed, .cancelled, .interrupted]
        {
            #expect(AgentWorkPresentation.isExpandedByDefault(for: state))
        }
    }

    @Test func toolStateAndMixedBatchPreserveFailureSemantics() {
        let states: [(AgentToolCard.State, AgentToolPresentation.BatchTint)] = [
            (.proposed, .secondary), (.running, .secondary), (.reviewing, .warning),
            (.waitingForUser, .warning), (.waitingForApproval, .warning), (.completed, .success),
            (.failed, .failure), (.denied, .failure), (.interrupted, .secondary),
        ]
        for (state, tint) in states { #expect(AgentToolPresentation.tint(for: state) == tint) }
        let completed = card(state: .completed)
        let failed = card(state: .failed)
        #expect(AgentToolPresentation.batchTint(for: [completed, failed]) == .warning)
        let title = AgentToolPresentation.batchSummary(for: [completed, failed], locale: Locale(identifier: "en"))
        #expect(title.localizedCaseInsensitiveContains("failed"))
        #expect(AgentToolPresentation.batchTint(for: [completed, card(state: .waitingForApproval)]) == .warning)
    }

    @Test func aDirectDenialBeforeTheChannelDrainsKeepsOneDeniedCard() async throws {
        let value = card(state: .proposed)
        let conversation = ConversationModel()
        let request = AgentApprovalRequest(
            invocation: value.invocation, descriptor: value.descriptor, userIntent: "Inspect")
        let answer = Task { await conversation.requestApproval(request) }
        defer { conversation.respondToApproval(request.id, allow: false) }
        for _ in 0..<100 where conversation.pendingApprovals.isEmpty { await Task.yield() }
        _ = try #require(conversation.pendingApprovals.first)
        conversation.respondToApproval(request.id, allow: false)
        _ = await answer.value
        conversation.handle(.toolProposed(value.invocation, value.descriptor))
        conversation.handle(.approvalRequested(request))
        conversation.handle(
            .toolFinished(
                value.invocation,
                .init(
                    callID: value.invocation.call.id, content: "Denied", isError: true
                )))
        #expect(conversation.toolCards.count == 1)
        #expect(conversation.toolCards.first?.state == .denied)
        #expect(conversation.transcript.count == 1)
    }

    @Test func approvalPolicyDenialFinishesAsDeniedRatherThanFailed() {
        let value = card(state: .proposed)
        let conversation = ConversationModel()
        conversation.handle(.toolProposed(value.invocation, value.descriptor))
        conversation.handle(
            .toolFinished(
                value.invocation,
                AgentToolResult(
                    callID: value.invocation.call.id, content: "Denied", isError: true,
                    metadata: [AgentToolResult.approvalPolicyDeniedKey: .bool(true)]
                )))

        #expect(conversation.toolCards.first?.state == .denied)
    }

    @Test func resultProjectionUsesTheInjectedPresenterAndRetainsFullCopyOutput() throws {
        var value = card(state: .completed)
        value.result = AgentToolResult(callID: value.invocation.call.id, content: "{\"answer\":42}")
        let presenter = AgentToolDetailPresenter(id: "test.answer") { input in
            [.field(.init(label: "Answer", value: input.result.objectValue?["answer"]?.encodedString ?? "missing"))]
        }
        let detail = try #require(AgentToolPresentation.detail(for: value, presenter: presenter))
        #expect(detail.items == [.field(.init(label: "Answer", value: "42"))])
        let full = (0..<250).map { "line \($0): " + String(repeating: "日", count: 80) }.joined(separator: "\n")
        let preview = AgentToolPresentation.preview(full)
        #expect(preview.isShortened)
        #expect(preview.full == full)
        #expect(preview.displayed.hasPrefix("line 0:"))
        #expect(preview.displayed.contains("line 249:"))
        #expect(preview.displayed.utf8.count <= AgentToolPresentation.displayByteLimit)
        #expect(preview.displayed.split(separator: "\n", omittingEmptySubsequences: false).count <= 120)
    }

    @Test func reasoningTitlesKeepEmphasisLinksAndImageAltText() {
        let title = TermindMarkdownParser.inlineTitle(
            "## **Inspect**\n\n`nginx` [logs](https://example.com) ![alt](https://example.com/p.png)")
        #expect(String(title.characters) == "Inspect nginx logs alt")
        #expect(title.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(title.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        let localLink = TermindMarkdownParser.inlineTitle("[command](file:///tmp/local)")
        #expect(String(localLink.characters) == "command")
        #expect(localLink.runs.contains { $0.link == URL(string: "file:///tmp/local") })
    }

    private func work(id: UUID, state: AgentRunState, afterAnswer: Bool = false) -> AssistantTranscriptEntry {
        .init(
            id: id,
            content: .work(
                .init(
                    run: .init(id: id, state: state, startedAt: .distantPast), items: [], orderedAt: .distantPast,
                    appearsAfterAnswer: afterAnswer
                )))
    }

    private func card(state: AgentToolCard.State) -> AgentToolCard {
        .init(
            invocation: .init(
                runID: UUID(), call: .init(id: UUID().uuidString, name: "inspect", arguments: .object([:]))),
            descriptor: .init(
                name: "inspect", summary: "Inspect", inputSchema: .object([:]), target: .host,
                approvalPolicy: .approve, concurrency: .parallel),
            state: state
        )
    }

    @Test
    func aReaderToggleSurvivesDefaultStateTransitions() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()

        #expect(state.isExpanded(.work(id), default: true))
        state.toggleDisclosure(.work(id), default: true)
        #expect(!state.isExpanded(.work(id), default: true))
        #expect(state.readerDidToggle(.work(id)))

        state.followDefault(true, for: .work(id))
        #expect(!state.isExpanded(.work(id), default: true))
    }

    @Test
    func untouchedDisclosureFollowsItsRuntimeDefault() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()

        state.followDefault(true, for: .work(id))
        #expect(state.isExpanded(.work(id)))
        #expect(!state.readerDidToggle(.work(id)))
    }

    @Test
    func deferredAutoCollapseWaitsForTheCoordinatorAndRespectsReaderOverride() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()

        state.deferAutoCollapse(id)
        #expect(state.isExpanded(.work(id)))
        #expect(state.hasPendingAutoCollapse(id))
        #expect(state.completeAutoCollapse(id))
        #expect(!state.isExpanded(.work(id)))

        state.deferAutoCollapse(id)
        state.toggleDisclosure(.work(id), default: true)
        #expect(!state.hasPendingAutoCollapse(id))
        #expect(!state.completeAutoCollapse(id))
    }

    @Test
    func reasoningDeadlineIsAbsoluteAndNewMarkdownResetsIt() {
        let id = UUID()
        let state = AssistantTranscriptPresentationState()
        let start = Date(timeIntervalSince1970: 1_000)

        let first = state.reasoningTitleDeadline(
            for: id, revision: "first", now: start
        )
        #expect(first == start.addingTimeInterval(3))
        #expect(
            state.reasoningTitleDeadline(
                for: id, revision: "first", now: start.addingTimeInterval(2)
            ) == first)
        #expect(
            state.reasoningTitleDeadline(
                for: id, revision: "second", now: start.addingTimeInterval(2)
            ) == start.addingTimeInterval(5))
    }

}

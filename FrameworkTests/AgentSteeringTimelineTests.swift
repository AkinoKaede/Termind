// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import TermindApplication
import TermindPersistence
import TermindPresentation
import Testing

@Suite(.timeLimit(.minutes(1))) @MainActor
struct AgentSteeringTimelineTests {
    @Test func deliveryClosesOldWorkAndStartsNewReasoningBelowTheUserMessage() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        let original = try #require(conversation.workGroups.first)
        let steering = deliver(conversation, at: 120)

        #expect(conversation.workGroups.map(\.id) == [original.id])
        let closed = try #require(conversation.workGroups.first)
        #expect(closed.presentationState == .completed)
        #expect(closed.run.state == .running)
        #expect(closed.finishedAt == date(120))

        let response = AgentTranscriptMessage(role: .assistant, createdAt: date(121))
        conversation.handle(.messageStarted(response))
        let placeholder = try #require(conversation.workGroups.last)
        #expect(placeholder.id != original.id)
        #expect(placeholder.boundaryMessageID == steering.id)
        #expect(placeholder.startedAt == date(120))
        #expect(kinds(conversation) == [.user, .work, .user, .work])

        conversation.handle(.reasoningDelta(messageID: response.id, text: "Check the revised request."))
        #expect(conversation.workGroups.map(\.id) == [original.id, placeholder.id])
        #expect(conversation.workGroups.first?.activeReasoningBlockID == nil)
        #expect(conversation.workGroups.last?.activeReasoningBlockID != nil)

        conversation.handle(
            .modelRetryScheduled(
                .init(runID: runID, messageID: response.id, attempt: 1, maximumAttempts: 3)))
        #expect(conversation.workGroups.first?.retryProgress == nil)
        #expect(conversation.workGroups.last?.retryProgress?.messageID == response.id)

        conversation.handle(
            .messageFinished(
                .init(id: response.id, role: .assistant, text: "Revised answer", createdAt: response.createdAt)))
        finish(conversation, runID: runID)
        #expect(kinds(conversation) == [.user, .work, .user, .assistant])
        #expect(conversation.workGroups.first?.finishedAt == date(120))
    }

    @Test func toolBatchesSpanProviderTurnsButNotDeliveredUserMessages() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before-1", at: 110)
        tool(conversation, runID: runID, callID: "before-2", at: 111)
        let firstID = try #require(conversation.workGroups.first?.id)
        deliver(conversation, at: 120)
        tool(conversation, runID: runID, callID: "after-1", at: 121)
        let secondID = try #require(conversation.workGroups.last?.id)
        tool(conversation, runID: runID, callID: "after-2", at: 119)

        #expect(conversation.workGroups.map(\.id) == [firstID, secondID])
        #expect(
            conversation.workGroups.map { calls($0) } == [
                ["before-1", "before-2"], ["after-1", "after-2"],
            ])
        #expect(conversation.workGroups.allSatisfy { $0.run.id == runID })
        #expect(kinds(conversation) == [.user, .work, .user, .work])
    }

    @Test func consecutiveDeliveriesDoNotProduceEmptyWorkGroups() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        deliver(conversation, at: 120)
        let last = deliver(
            conversation, at: 120,
            origin: .init(sourceConversationID: UUID(), sourceRunID: UUID(), sourceToolCallID: "send"))
        #expect(kinds(conversation) == [.user, .work, .user, .user])

        tool(conversation, runID: runID, callID: "after", at: 121)
        #expect(conversation.workGroups.count == 2)
        #expect(conversation.workGroups.last?.boundaryMessageID == last.id)
        #expect(kinds(conversation) == [.user, .work, .user, .user, .work])
    }

    @Test(arguments: [AgentRunState.cancelled, .failed, .interrupted])
    func lateToolUpdatesAndTerminalStateStayWithTheirOwnSegment(state: AgentRunState) throws {
        let (conversation, runID) = begin()
        let earlier = tool(conversation, runID: runID, callID: "before", at: 110, completed: false)
        deliver(conversation, at: 120)
        tool(conversation, runID: runID, callID: "after", at: 121)
        let ids = conversation.workGroups.map(\.id)
        conversation.handle(
            .toolFinished(
                earlier, .init(callID: earlier.call.id, content: "Late failure", isError: true)))
        finish(conversation, runID: runID, state: state)

        #expect(conversation.workGroups.map(\.id) == ids)
        #expect(conversation.workGroups.map(\.presentationState) == [.completed, state])
        #expect(conversation.workGroups.first?.finishedAt == date(120))
        #expect(conversation.workGroups.last?.finishedAt == date(150))
        #expect(conversation.workGroups.map { calls($0) } == [["before"], ["after"]])
        let oldCard = try #require(cards(conversation.workGroups[0]).first)
        #expect(oldCard.state == .failed)
        #expect(oldCard.result?.content == "Late failure")
        if state == .failed { #expect(kinds(conversation).last == .failure) }
    }

    @Test(arguments: [false, true])
    func supplementalRowsCannotReorderEqualOrBackwardMessageClocks(backward: Bool) throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 100)
        let cut = conversation.transcript.count
        let steering = deliver(conversation, at: backward ? 80 : 100)
        tool(conversation, runID: runID, callID: "after", at: backward ? 60 : 100)
        tool(conversation, runID: runID, callID: "suggest", at: backward ? 40 : 100, name: "terminal_suggest")
        conversation.handle(
            .messageFinished(
                .init(role: .assistant, text: "Answer", createdAt: date(backward ? 20 : 100))))
        conversation.handle(
            .planPresented(
                .init(title: "Plan", body: "Plan body", scratchPath: "/tmp/plan.md", createdAt: date(1))))
        finish(conversation, runID: runID, state: .failed)
        let record = try #require(conversation.prepareCompaction(summary: "Earlier work", cut: cut))
        conversation.applyCompaction(record, cut: cut)

        #expect(
            kinds(conversation) == [.user, .work, .compaction, .user, .work, .command, .assistant, .plan, .failure])
        #expect(conversation.workGroups.last?.boundaryMessageID == steering.id)
        #expect(conversation.workGroups.map { calls($0) } == [["before"], ["after"]])
        #expect(conversation.workGroups.allSatisfy { ($0.finishedAt ?? $0.startedAt) >= $0.startedAt })
    }

    @Test func missingSourceIdentityUsesRunLocalCallOwnershipBeforeTimestamps() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        deliver(conversation, at: 120)
        tool(conversation, runID: runID, callID: "after", at: 121)
        for index in conversation.toolCards.indices {
            conversation.toolCards[index].invocation.sourceMessageID = nil
            conversation.toolCards[index].invocation.createdAt = date(1)
        }
        #expect(conversation.workGroups.map { calls($0) } == [["before"], ["after"]])
        #expect(kinds(conversation) == [.user, .work, .user, .work])
    }

    @Test func unknownLegacyToolOwnershipFallsBackWithoutDroppingOrDuplicatingCards() throws {
        let (conversation, runID) = begin()
        deliver(conversation, at: 120)
        for (callID, instant) in [("legacy-before", 110.0), ("legacy-after", 130.0)] {
            let invocation = AgentToolInvocation(
                runID: runID, call: .init(id: callID, name: "inspect", arguments: .object([:])),
                createdAt: date(instant))
            conversation.handle(.toolProposed(invocation, descriptor()))
        }
        #expect(conversation.workGroups.map { calls($0) } == [["legacy-before"], ["legacy-after"]])
        #expect(kinds(conversation) == [.user, .work, .user, .work])
    }

    @Test func visibleSegmentClosureDefersCollapseAndKeepsReaderChoicesIndependent() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        let before = entries(conversation)
        let oldID = try #require(conversation.workGroups.first?.id)
        let presentation = AssistantTranscriptPresentationState()
        deliver(conversation, at: 120)
        tool(conversation, runID: runID, callID: "after", at: 121)
        let newID = try #require(conversation.workGroups.last?.id)
        presentation.prepareWorkCompletionTransitions(
            from: before, to: entries(conversation), visibleIDs: [oldID])

        #expect(presentation.hasPendingAutoCollapse(oldID))
        #expect(presentation.isExpanded(.work(oldID)))
        presentation.toggleDisclosure(.work(newID), default: true)
        #expect(presentation.collapseWorkOutsideViewport(visibleIDs: [newID]) == [oldID])
        #expect(!presentation.isExpanded(.work(oldID)))
        #expect(!presentation.isExpanded(.work(newID), default: true))
        #expect(presentation.readerDidToggle(.work(newID)))
    }

    @Test(arguments: [false, true])
    func diskReopenReconstructsTheSameSegmentsAndStableIDs(compacted: Bool) async throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        let cut = conversation.transcript.count
        deliver(conversation, at: 90)
        tool(conversation, runID: runID, callID: "after", at: 80)
        conversation.handle(.messageFinished(.init(role: .assistant, text: "Answer", createdAt: date(70))))
        finish(conversation, runID: runID)
        let compaction = compacted ? conversation.prepareCompaction(summary: "Earlier work", cut: cut) : nil
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.store")
        try await persist(conversation, runID: runID, to: url, compaction: compaction)
        if let compaction { conversation.applyCompaction(compaction, cut: cut) }
        let ids = conversation.timeline.map(\.id)

        let container = try TermindPersistence.makeContainer(url: url)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        let store = AssistantConversationStore()
        store.restore(try await repository.loadConversations())
        let restored = try #require(store.conversations.first)
        #expect(restored.timeline.map(\.id) == ids)
        #expect(restored.workGroups.map { calls($0) } == [["before"], ["after"]])
        #expect(restored.workGroups.map(\.finishedAt) == conversation.workGroups.map(\.finishedAt))
    }

    @Test func editingAndForkingKeepOnlyTheOwnedWorkSegments() throws {
        let (conversation, runID) = begin()
        tool(conversation, runID: runID, callID: "before", at: 110)
        let earlierPlan = AgentPlan(
            title: "Earlier plan", body: "Retain", scratchPath: "/tmp/earlier.md", createdAt: date(500))
        conversation.handle(.planPresented(earlierPlan))
        let steering = deliver(conversation, at: 120)
        tool(conversation, runID: runID, callID: "after", at: 121)
        let answer = AgentTranscriptMessage(role: .assistant, text: "Answer", createdAt: date(130))
        conversation.handle(.messageFinished(answer))
        conversation.handle(
            .planPresented(
                .init(title: "Later plan", body: "Remove", scratchPath: "/tmp/later.md", createdAt: date(1))))
        finish(conversation, runID: runID)
        let fork = try #require(conversation.forked(throughAssistantMessage: answer.id))
        #expect(fork.workGroups.map { calls($0) } == [["before"], ["after"]])
        #expect(kinds(fork) == [.user, .work, .user, .work, .assistant])

        _ = try #require(conversation.editUserMessage(steering.id, authoredText: "Replacement"))
        #expect(conversation.workGroups.map { calls($0) } == [["before"]])
        #expect(conversation.plans.map(\.id) == [earlierPlan.id])
        #expect(kinds(conversation) == [.user, .work, .plan, .user])
    }

    private func begin() -> (ConversationModel, UUID) {
        let user = AgentTranscriptMessage(role: .user, text: "Inspect", authoredText: "Inspect", createdAt: date(100))
        let conversation = ConversationModel(
            messages: [.init(id: user.id, role: .user, text: user.text, createdAt: user.createdAt)],
            transcript: [user])
        let runID = UUID()
        conversation.handle(.runStarted(.init(id: runID, state: .running, startedAt: date(100))))
        conversation.handle(.runState(.running))
        return (conversation, runID)
    }

    @discardableResult
    private func deliver(
        _ conversation: ConversationModel, at instant: TimeInterval, origin: AgentMessageOrigin? = nil
    ) -> AgentTranscriptMessage {
        let message = AgentTranscriptMessage(
            role: .user, text: "Revised request", origin: origin, createdAt: date(instant))
        conversation.handle(.steeringDelivered(message))
        return message
    }

    @discardableResult
    private func tool(
        _ conversation: ConversationModel, runID: UUID, callID: String, at instant: TimeInterval,
        completed: Bool = true, name: String = "inspect"
    ) -> AgentToolInvocation {
        let call = AgentToolCall(id: callID, name: name, arguments: .object(["command": .string("pwd")]))
        let source = AgentTranscriptMessage(role: .assistant, toolCalls: [call], createdAt: date(instant))
        conversation.handle(.messageStarted(source))
        conversation.handle(.messageFinished(source))
        conversation.handle(.turnFinished(index: 0, stopReason: .toolCalls))
        let invocation = AgentToolInvocation(
            runID: runID, call: call, sourceMessageID: source.id, createdAt: date(instant))
        conversation.handle(.toolProposed(invocation, descriptor(name)))
        conversation.handle(.toolStarted(invocation))
        if completed { conversation.handle(.toolFinished(invocation, .init(callID: callID, content: "done"))) }
        return invocation
    }

    private func finish(_ conversation: ConversationModel, runID: UUID, state: AgentRunState = .completed) {
        conversation.handle(
            .runFinished(
                .init(
                    id: runID, state: state, startedAt: date(100), finishedAt: date(150),
                    failure: state == .failed ? "Run failed" : nil)))
        conversation.handle(.runState(state))
    }

    private func descriptor(_ name: String = "inspect") -> AgentToolDescriptor {
        .init(name: name, summary: name, inputSchema: .object([:]), target: .local, approvalPolicy: .approve)
    }

    private func entries(_ conversation: ConversationModel) -> [AssistantTranscriptEntry] {
        AssistantTranscriptEntry.items(
            timeline: conversation.timeline, isInterrupted: false, canEdit: { _ in false }, canFork: { _ in false })
    }

    private func kinds(_ conversation: ConversationModel) -> [AssistantTranscriptEntry.Kind] {
        entries(conversation).map(\.kind)
    }

    private func cards(_ group: AgentWorkGroup) -> [AgentToolCard] {
        group.items.flatMap { item -> [AgentToolCard] in
            switch item {
            case .tools(let batch): return batch.cards
            case .tool(let card): return [card]
            default: return []
            }
        }
    }

    private func calls(_ group: AgentWorkGroup) -> [String] { cards(group).map(\.invocation.call.id) }
    private func date(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func persist(
        _ conversation: ConversationModel, runID: UUID, to url: URL, compaction: AgentCompactionRecord?
    ) async throws {
        let container = try TermindPersistence.makeContainer(url: url)
        let repository = SwiftDataAgentRunRepository(context: container.mainContext)
        try await repository.save(
            .init(
                id: runID, conversationID: conversation.id, state: .completed, permissionMode: .askForApproval,
                messages: conversation.transcript, startedAt: date(100), finishedAt: date(150)))
        for card in conversation.toolCards {
            try await repository.record(.toolProposed(card.invocation, card.descriptor), runID: runID)
            if let result = card.result {
                try await repository.record(.toolFinished(card.invocation, result), runID: runID)
            }
        }
        if let compaction { try await repository.persistCompaction(compaction, conversationID: conversation.id) }
    }
}

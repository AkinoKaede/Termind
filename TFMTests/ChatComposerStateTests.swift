import AgentKit
import AppKit
import Foundation
import SwiftUI
import TermindApplication
import TermindDomain
import TermindInfrastructure
import TermindPresentation
import TermindRemoteInfrastructure
import Testing

@testable import Termind
@testable import TermindRemoteInfrastructure

private struct ImmediateConversationAgentModel: AgentModelStreaming {
    var turns: [[AgentModelStreamEvent]]
    let cursor = ImmediateConversationCursor()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                let index = await cursor.next()
                for event in turns[min(index, turns.count - 1)] {
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}

private actor ImmediateConversationCursor {
    var value = 0
    func next() -> Int {
        defer { value += 1 }
        return value
    }
}

private actor ConversationExecutionCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor ConversationCancellationProbe {
    var started = false
    var cancelled = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func startAndWaitForCancellation() async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                cancellationWaiters[id] = continuation
                if Task.isCancelled {
                    cancelWaiter(id)
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = cancellationWaiters.removeValue(forKey: id) else { return }
        cancelled = true
        waiter.resume(throwing: CancellationError())
    }
}

@Suite
@MainActor
struct ChatComposerStateTests {
    @Test
    func textEditorScrollerAppearsOnlyWhenItsDocumentOverflows() async throws {
        let state = ComposerScrollerTestState()
        let hosting = NSHostingView(
            rootView: ComposerScrollerTestView(state: state)
                .frame(width: 320, height: 80)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        let emptyScroller = try await requireComposerScroller(in: hosting)
        #expect(emptyScroller.autohidesScrollers)
        #expect(emptyScroller.hasVerticalScroller)
        #expect(emptyScroller.verticalScroller?.isHidden == true)
        #expect(emptyScroller.verticalScroller?.isEnabled == false)

        state.text = Array(repeating: "A line of composer text", count: 40).joined(separator: "\n")
        let overflowingScroller = try await requireComposerScroller(in: hosting) {
            $0.verticalScroller?.isEnabled == true
        }
        #expect(overflowingScroller.autohidesScrollers)

        state.text = "Short again"
        let shortScroller = try await requireComposerScroller(in: hosting) {
            $0.verticalScroller?.isEnabled == false
        }
        #expect(shortScroller.verticalScroller?.isHidden == true)
    }

    @Test
    func largePasteThresholdUsesCharactersOrLines() {
        #expect(!ContextAttachmentImporter.shouldAttachPastedText(String(repeating: "x", count: 1_999)))
        #expect(ContextAttachmentImporter.shouldAttachPastedText(String(repeating: "x", count: 2_000)))
        #expect(
            !ContextAttachmentImporter.shouldAttachPastedText(
                Array(repeating: "line", count: 19).joined(separator: "\n")
            ))
        #expect(
            ContextAttachmentImporter.shouldAttachPastedText(
                Array(repeating: "line", count: 20).joined(separator: "\n")
            ))
    }

    @Test
    func conversationOwnedFileImportFinishesAndKeepsFilename() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("attached through page drop".utf8).write(to: url)
        let conversation = ConversationModel()

        conversation.attachmentLoader = .live
        conversation.importAttachmentFiles([url])
        // The import reads the file off the main actor, so yielding only lets
        // other main-actor work run and can return before the read finishes.
        // Sleeping suspends until the reader actually reports back.
        for _ in 0..<100 where !conversation.composer.pendingAttachments.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(conversation.composer.pendingAttachments.isEmpty)
        #expect(conversation.composer.attachments.map(\.label) == [url.lastPathComponent])
        #expect(conversation.composer.attachments.first?.content == "attached through page drop")
    }

    @Test
    func conversationOwnedImportHonorsAttachmentLimitBeforeStartingTasks() {
        let conversation = ConversationModel()
        for index in 0..<ContextAttachmentImporter.maximumAttachments {
            // Distinct content, not just distinct labels: `attach` deduplicates
            // on kind and content, so chips that differ only by label collapse
            // into one and the composer never reaches the limit under test.
            conversation.attach(
                ContextChip(kind: .output, label: "item \(index)", content: "item \(index)")
            )
        }

        conversation.attachmentLoader = .live
        conversation.importAttachmentFiles([URL(fileURLWithPath: "/tmp/extra.txt")])

        #expect(conversation.composer.pendingAttachments.isEmpty)
        #expect(conversation.composer.attachments.count == ContextAttachmentImporter.maximumAttachments)
        #expect(conversation.composer.attachmentImportError != nil)
    }

    @Test
    func imageAttachmentIsConsumedIntoVisibleAndModelFacingTurn() throws {
        let image = AgentImageAttachment(
            label: "graph.png", mimeType: "image/png", data: Data([9, 8, 7]),
            pixelWidth: 40, pixelHeight: 30
        )
        let conversation = ConversationModel()
        conversation.attach(ContextChip(kind: .image, label: image.label, image: image))

        let sent = conversation.appendUserTurnContent("What does this show?")

        #expect(sent.images == [image])
        #expect(conversation.messages.last?.contextChips.map(\.label) == ["graph.png"])
        #expect(conversation.messages.last?.images == [image])
        #expect(conversation.transcript.last?.images == [image])
        #expect(conversation.composer.attachments.isEmpty)
    }

    /// `/skill` has to reach the model without reaching the bubble: the user
    /// typed a question, not a directive, and that is what message editing
    /// reopens and what the title generator reads.
    @Test
    func anArmedSkillIsSentToTheModelButNotShownAsTypedText() throws {
        let conversation = ConversationModel()
        conversation.composer.armedSkillName = "disk-triage"

        let sent = conversation.appendUserTurnContent("root is at 99%")

        #expect(sent.authoredText == "root is at 99%")
        #expect(sent.text.contains("<use_skill name=\"disk-triage\">"))
        #expect(sent.text.contains("skill_read_file"))
        #expect(conversation.messages.last?.text == "root is at 99%")
        #expect(conversation.transcript.last?.authoredText == "root is at 99%")
        #expect(try #require(conversation.transcript.last).text.contains("disk-triage"))
        // Consumed with the attachments, so the chip going away is how the user
        // sees it went.
        #expect(conversation.composer.armedSkillName == nil)
    }

    @Test
    func anUnarmedComposerAddsNothingToTheModelFacingTurn() {
        let conversation = ConversationModel()
        let sent = conversation.appendUserTurnContent("root is at 99%")

        #expect(sent.text == "root is at 99%")
        #expect(sent.text == sent.authoredText)
    }

    @Test
    func aManualAttachmentMakesAnEmptyDraftSendable() {
        let conversation = ConversationModel()
        #expect(!conversation.canSendDraft)

        conversation.attach(
            ContextChip(
                kind: .output, label: "Last lines", content: "service failed"
            ))
        #expect(conversation.canSendDraft)

        conversation.sendDraft()

        #expect(conversation.messages.last?.text == "")
        #expect(conversation.messages.last?.contextChips.map(\.label) == ["Last lines"])
        #expect(conversation.transcript.last?.text.contains("service failed") == true)
        #expect(
            conversation.transcript.last?.contextAttachments.first?.data
                == Data("service failed".utf8))
        #expect(conversation.composer.attachments.isEmpty)
    }

    @Test
    func imageOnlyTurnIsValidAndSuppliesItsFallbackTitle() {
        let image = AgentImageAttachment(
            label: "dashboard.png", mimeType: "image/png", data: Data([1, 2, 3]),
            pixelWidth: 10, pixelHeight: 10
        )
        let conversation = ConversationModel()
        conversation.attach(ContextChip(kind: .image, label: image.label, image: image))

        conversation.sendDraft()

        #expect(conversation.transcript.last?.text == "")
        #expect(conversation.transcript.last?.images == [image])
        #expect(conversation.derivedTitle == "dashboard.png")
    }

    @Test
    func legacyFileReferenceFallsBackToExtractedText() throws {
        let text = "\n\n<file label=\"manual.pdf\">\nExtracted body\n</file>"
        let reference = try #require(ContextChip.visibleReferences(in: text).first)

        #expect(reference.attachment?.suggestedFilename == "manual extracted.txt")
        #expect(reference.attachment?.isOriginalFile == false)
        #expect(reference.attachment?.data == Data("Extracted body".utf8))
    }

    @Test
    func activeFormKeysYieldToImeAndConsumeOnlyPlainReturnOrEscape() {
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 36, hasModifiers: false, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: true
            ) == .submit)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 53, hasModifiers: false, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: false
            ) == .cancel)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 76, hasModifiers: false, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: true
            ) == .submit)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 36, hasModifiers: false, hasMarkedText: true,
                isRepeat: false, isDefaultEnabled: true
            ) == .passThrough)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 36, hasModifiers: false, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: false
            ) == .consume)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 36, hasModifiers: false, hasMarkedText: false,
                isRepeat: true, isDefaultEnabled: true
            ) == .consume)
        #expect(
            ActiveFormKeyDecision.resolve(
                keyCode: 36, hasModifiers: true, hasMarkedText: false,
                isRepeat: false, isDefaultEnabled: true
            ) == .passThrough)
    }

    @Test
    func sidebarEscapeYieldsToAVisibleDecisionForm() {
        #expect(
            !AssistantSidebarEscapePolicy.shouldCloseConversation(
                hasConversation: true,
                hasBlockingInteraction: true
            ))
        #expect(
            AssistantSidebarEscapePolicy.shouldCloseConversation(
                hasConversation: true,
                hasBlockingInteraction: false
            ))
        #expect(
            !AssistantSidebarEscapePolicy.shouldCloseConversation(
                hasConversation: false,
                hasBlockingInteraction: false
            ))
    }

    @Test
    func reasoningEffortDefaultsToMedium() {
        #expect(ConversationModel().reasoningEffort == .medium)
    }

    @Test
    func reasoningEffortStaysScopedToItsConversation() {
        let first = ConversationModel()
        let second = ConversationModel()

        first.reasoningEffort = .max

        #expect(first.reasoningEffort == .max)
        #expect(second.reasoningEffort == .medium)
    }

    @Test
    func modelSelectionStillFeedsUnsetConversationsWithoutOverridingExplicitOnes() {
        let firstModel = AIModel(id: "first")
        let secondModel = AIModel(id: "second")
        let provider = ModelProvider(
            name: "Test Provider",
            models: [firstModel, secondModel]
        )
        let store = AIConfigurationModel(modelProviders: [provider], persistsSecrets: false)
        let firstRef = AIModelRef(modelProviderID: provider.id, modelID: firstModel.id)
        let secondRef = AIModelRef(modelProviderID: provider.id, modelID: secondModel.id)

        #expect(store.resolve(conversation: nil)?.model.id == firstModel.id)

        store.select(secondRef)

        #expect(store.resolve(conversation: nil)?.model.id == secondModel.id)
        #expect(store.resolve(conversation: firstRef)?.model.id == firstModel.id)
    }

    @Test
    func messageEventsUpsertWhenAnEarlierStreamingEventWasMissed() {
        let conversation = ConversationModel()
        let deltaID = UUID()
        conversation.handle(.messageDelta(messageID: deltaID, text: "streamed"))

        #expect(conversation.messages.count == 1)
        #expect(conversation.messages[0].id == deltaID)
        #expect(conversation.messages[0].text == "streamed")
        #expect(conversation.messages[0].isStreaming)

        let finishedID = UUID()
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: finishedID, role: .assistant, text: "finished"
                )))

        #expect(conversation.messages.count == 2)
        #expect(conversation.messages[1].id == finishedID)
        #expect(conversation.messages[1].text == "finished")
        #expect(!conversation.messages[1].isStreaming)
    }

    @Test
    func stoppingBeforeAnswerHidesTheWorkingPlaceholder() throws {
        let (conversation, _, assistant) = beginStreamingConversation()

        conversation.stop()

        let stoppedMessage = try #require(
            conversation.messages.first { $0.id == assistant.id }
        )
        #expect(!stoppedMessage.isStreaming)
        #expect(conversation.runState == .cancelled)
        #expect(conversation.timeline.map(timelineKind) == ["user", "work"])
        #expect(conversation.workGroups.first?.run.state == .cancelled)
    }

    @Test
    func stoppingDuringReasoningEndsItsActivePresentation() throws {
        let (conversation, _, assistant) = beginStreamingConversation()
        conversation.handle(
            .reasoningDelta(
                messageID: assistant.id, text: "Evaluating the request."
            ))
        #expect(conversation.workGroups.first?.activeReasoningBlockID != nil)

        conversation.stop()

        let stoppedMessage = try #require(
            conversation.messages.first { $0.id == assistant.id }
        )
        #expect(!stoppedMessage.isStreaming)
        #expect(stoppedMessage.reasoning.map(\.text) == ["Evaluating the request."])
        #expect(conversation.workGroups.first?.activeReasoningBlockID == nil)
        #expect(conversation.timeline.map(timelineKind) == ["user", "work"])
    }

    @Test
    func stoppingAPartialAnswerKeepsItsTextWithoutAStreamingCaret() throws {
        let (conversation, _, assistant) = beginStreamingConversation()
        conversation.handle(.messageDelta(messageID: assistant.id, text: "Partial answer"))

        conversation.stop()

        let stoppedMessage = try #require(
            conversation.messages.first { $0.id == assistant.id }
        )
        #expect(stoppedMessage.text == "Partial answer")
        #expect(!stoppedMessage.isStreaming)
        #expect(conversation.timeline.map(timelineKind) == ["user", "assistant", "work"])
    }

    @Test
    func stoppingAWorkingToolInterruptsItAndSettlesItsMessage() throws {
        let (conversation, runID, assistant) = beginStreamingConversation()
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(id: "call-1", name: "lookup", arguments: .object([:])),
            sourceMessageID: assistant.id
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))
        conversation.handle(.toolStarted(invocation))

        conversation.stop()

        #expect(conversation.toolCards.first?.state == .interrupted)
        #expect(conversation.messages.allSatisfy { !$0.isStreaming })
        #expect(conversation.workGroups.first?.run.state == .cancelled)
    }

    @Test
    func workingPlaceholderDisappearsAsSoonAsAToolIsVisible() throws {
        let (conversation, runID, assistant) = beginStreamingConversation()
        let before = try #require(conversation.workGroups.first)
        #expect(before.items.contains { if case .message = $0 { true } else { false } })

        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: assistant.id,
                    role: .assistant,
                    toolCalls: [
                        AgentToolCall(
                            id: "call-1", name: "lookup", arguments: .object([:])
                        )
                    ],
                    createdAt: assistant.createdAt
                )))
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(id: "call-1", name: "lookup", arguments: .object([:])),
            sourceMessageID: assistant.id
        )

        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))

        let after = try #require(conversation.workGroups.first)
        #expect(!after.items.contains { if case .message = $0 { true } else { false } })
        guard case .tools(let batch) = try #require(after.items.first) else {
            Issue.record("Expected the visible tool to replace Working")
            return
        }
        #expect(batch.cards.map(\.id) == [invocation.id])
    }

    @Test
    func existingWorkOutputSuppressesLaterWorkingButStillAcceptsReasoning() throws {
        let conversation = ConversationModel()
        let runID = UUID()
        let first = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [
                AgentToolCall(
                    id: "call-1", name: "lookup", arguments: .object([:])
                )
            ]
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: first.createdAt
                )))
        conversation.handle(.messageStarted(first))
        conversation.handle(.messageFinished(first))
        let invocation = AgentToolInvocation(
            runID: runID,
            call: first.toolCalls[0],
            sourceMessageID: first.id
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))

        let next = AgentTranscriptMessage(role: .assistant)
        conversation.handle(.turnStarted(index: 1))
        conversation.handle(.messageStarted(next))

        let group = try #require(conversation.workGroups.first)
        #expect(
            !group.items.contains { item in
                guard case .message(let message) = item else { return false }
                return message.id == next.id
            })
        #expect(group.items.contains { if case .tools = $0 { true } else { false } })

        conversation.handle(
            .reasoningDelta(
                messageID: next.id,
                text: "Evaluate the first result."
            ))
        let updated = try #require(conversation.workGroups.first)
        #expect(
            !updated.items.contains { item in
                guard case .message(let message) = item else { return false }
                return message.id == next.id
            })
        guard
            case .tools(let batch) = try #require(
                updated.items.first(where: { if case .tools = $0 { true } else { false } })
            )
        else {
            Issue.record("Expected reasoning to move into the tool title")
            return
        }
        #expect(batch.reasoning?.sourceMessageID == next.id)
        #expect(batch.reasoning?.markdown == "Evaluate the first result.")
    }

    @Test
    func reasoningAloneDoesNotSuppressTheNextWorkingPlaceholder() throws {
        let conversation = ConversationModel()
        let runID = UUID()
        let first = AgentTranscriptMessage(role: .assistant)
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: first.createdAt
                )))
        conversation.handle(.messageStarted(first))
        conversation.handle(
            .reasoningDelta(
                messageID: first.id,
                text: "First reasoning block."
            ))
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: first.id,
                    role: .assistant,
                    reasoning: [AgentReasoningBlock(text: "First reasoning block.")],
                    createdAt: first.createdAt
                )))
        conversation.handle(.turnFinished(index: 0, stopReason: .completed))

        let next = AgentTranscriptMessage(role: .assistant)
        conversation.handle(.turnStarted(index: 1))
        conversation.handle(.messageStarted(next))

        let group = try #require(conversation.workGroups.first)
        #expect(
            group.items.contains { item in
                guard case .message(let message) = item else { return false }
                return message.id == next.id && message.text.isEmpty
            })
    }

    @Test
    func newReasoningRemainsVisibleAfterTheExistingToolBatchIsTerminal() throws {
        let conversation = ConversationModel()
        let runID = UUID()
        let source = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [
                AgentToolCall(
                    id: "call-1", name: "lookup", arguments: .object([:])
                )
            ]
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: source.createdAt
                )))
        conversation.handle(.messageFinished(source))
        let invocation = AgentToolInvocation(
            runID: runID, call: source.toolCalls[0], sourceMessageID: source.id
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))
        conversation.handle(
            .toolFinished(
                invocation,
                AgentToolResult(callID: invocation.call.id, content: "ok")
            ))

        let next = AgentTranscriptMessage(role: .assistant)
        conversation.handle(.turnStarted(index: 1))
        conversation.handle(.messageStarted(next))
        let waiting = try #require(conversation.workGroups.first)
        #expect(
            !waiting.items.contains {
                if case .message = $0 { true } else { false }
            })

        conversation.handle(
            .reasoningDelta(
                messageID: next.id,
                text: "Reason about the completed result."
            ))

        let group = try #require(conversation.workGroups.first)
        #expect(
            group.items.contains { item in
                guard case .reasoning(let block) = item else { return false }
                return block.text == "Reason about the completed result."
            })
        guard
            case .tools(let batch) = try #require(
                group.items.first(where: { if case .tools = $0 { true } else { false } })
            )
        else {
            Issue.record("Expected the completed tool batch to remain")
            return
        }
        #expect(batch.reasoning == nil)
    }

    @Test
    func terminalRunEventSettlesAnUnfinishedMessage() {
        let (conversation, runID, assistant) = beginStreamingConversation()

        conversation.handle(
            .runFinished(
                AgentRunSummary(
                    id: runID, state: .failed, startedAt: .now, finishedAt: .now
                )))

        #expect(conversation.messages.first { $0.id == assistant.id }?.isStreaming == false)
    }

    @Test
    func everyRawDeltaIsImmediatelyVisibleWhileContextPublishingStaysThrottled() {
        let conversation = ConversationModel(
            contextEstimatePublishInterval: .seconds(60)
        )
        let assistant = AgentTranscriptMessage(role: .assistant)
        conversation.handle(.messageStarted(assistant))

        for _ in 0..<1_000 {
            conversation.handle(.messageDelta(messageID: assistant.id, text: "x"))
        }

        #expect(
            conversation.messages.first { $0.id == assistant.id }?.text
                == String(repeating: "x", count: 1_000)
        )
        #expect(conversation.contextEstimatePublishCount == 1)

        let final = AgentTranscriptMessage(
            id: assistant.id, role: .assistant,
            text: String(repeating: "x", count: 1_000),
            createdAt: assistant.createdAt
        )
        conversation.handle(.messageFinished(final))
        #expect(conversation.messages.first { $0.id == assistant.id }?.text == final.text)
        #expect(conversation.contextEstimatePublishCount == 2)
        #expect(
            conversation.contextEstimate
                == AgentContextEstimator.estimate(
                    systemPrompt: TermindAgentPolicy.systemPrompt,
                    toolSchemaCharacters: 0,
                    transcript: [final],
                    attachedCharacters: 0,
                    measured: nil
                )
        )
    }

    @Test
    func everyReasoningDeltaIsImmediatelyVisible() {
        let conversation = ConversationModel()
        let assistant = AgentTranscriptMessage(role: .assistant)
        conversation.handle(.messageStarted(assistant))

        conversation.handle(.reasoningDelta(messageID: assistant.id, text: "first"))
        conversation.handle(.reasoningDelta(messageID: assistant.id, text: " tail"))

        #expect(
            conversation.messages.first { $0.id == assistant.id }?.reasoning.map(\.text)
                == ["first tail"]
        )
    }

    @Test
    func stoppingSettlesAnImmediatelyPresentedPartialAnswer() {
        let conversation = ConversationModel(
            contextEstimatePublishInterval: .seconds(60)
        )
        let runID = UUID()
        let assistant = AgentTranscriptMessage(role: .assistant)
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: .now
                )))
        conversation.handle(.runState(.running))
        conversation.handle(.messageStarted(assistant))
        conversation.handle(.messageDelta(messageID: assistant.id, text: "first"))
        conversation.handle(.messageDelta(messageID: assistant.id, text: " tail"))

        conversation.stop()

        let visible = conversation.messages.first { $0.id == assistant.id }
        #expect(visible?.text == "first tail")
        #expect(visible?.isStreaming == false)
    }

    @Test
    func immediatelyCompletedRuntimeStillReachesTheConversation() async {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        let runtime = AgentRuntime(
            model: ImmediateConversationAgentModel(turns: [
                [
                    .textDelta("partial"), .textSnapshot("visible immediately"),
                    .finished(.completed),
                ]
            ]),
            tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )

        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "hello",
                permissionMode: .askForApproval
            ),
            repository: repository)
        await waitForTerminal(conversation)

        #expect(conversation.runState == .completed)
        #expect(
            conversation.messages.contains {
                $0.role == .assistant && $0.text == "visible immediately"
            })
    }

    @Test
    func toolCallContinuesToTheNextVisibleAssistantTurn() async {
        let executions = ConversationExecutionCounter()
        let model = ImmediateConversationAgentModel(turns: [
            [
                .toolCallDelta(id: "call-1", name: "lookup", arguments: #"{"stale":true}"#),
                .toolCallSnapshot(
                    id: "call-1", providerItemID: "item-1", name: "lookup",
                    arguments: #"{"query":"hosts"}"#
                ),
                // Compatible gateways sometimes report a generic completion
                // even though the assistant output contains a tool call. The
                // loop must follow the message content, not this hint.
                .finished(.completed),
            ],
            [.textDelta("tool result is visible"), .finished(.completed)],
        ])
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "lookup", summary: "lookup",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ]),
                    "required": .array([.string("query")]),
                    "additionalProperties": .bool(false),
                ]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            #expect(invocation.call.arguments == .object(["query": .string("hosts")]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "host-a")
        }
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
            repository: repository
        )

        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            ),
            repository: repository)
        await waitForTerminal(conversation)

        #expect(await executions.value == 1)
        #expect(conversation.runState == .completed)
        #expect(
            conversation.messages.contains {
                $0.role == .assistant && $0.text == "tool result is visible"
            })
    }

    /// `messages` is a display projection with no tool calls and no tool
    /// results. Replaying it as the next run's prior context dropped everything
    /// the agent had already done, and left an assistant turn with empty content
    /// — the shape Anthropic and Google answer with a 400.
    @Test
    func modelFacingHistoryKeepsToolCallsAndResults() async {
        let model = ImmediateConversationAgentModel(turns: [
            [
                .toolCallSnapshot(
                    id: "call-1", providerItemID: "item-1", name: "lookup",
                    arguments: #"{"query":"hosts"}"#
                ),
                .finished(.toolCalls),
            ],
            [.textDelta("host-a is up"), .finished(.completed)],
        ])
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "lookup", summary: "lookup",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["query": .object(["type": .string("string")])]),
                    "required": .array([.string("query")]),
                    "additionalProperties": .bool(false),
                ]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: "host-a")
        }
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("inspect")
        // The prompt travels on the request, so it must not also be replayed.
        #expect(conversation.pendingPriorMessages.isEmpty)

        conversation.start(
            runtime: AgentRuntime(
                model: model, tools: [tool],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)

        conversation.appendUserTurn("connect to it")
        let prior = conversation.pendingPriorMessages

        #expect(prior.map(\.role) == [.user, .assistant, .tool, .assistant])
        let call = prior.first { $0.role == .assistant }?.toolCalls.first
        #expect(call?.name == "lookup")
        #expect(call?.providerItemID == "item-1")
        #expect(
            prior.contains {
                $0.role == .tool && $0.toolCallID == "call-1" && $0.text == "host-a"
            })
        #expect(!prior.contains { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty })
    }

    /// Stop released the runtime reference before the cancelling task read it,
    /// so the run carried on executing tools with nobody listening.
    @Test
    func stopCancelsTheRunAndNotOnlyItsEventStream() async throws {
        let probe = ConversationCancellationProbe()
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "wait", summary: "wait",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .local, approvalPolicy: .approve
            )
        ) { invocation, _ in
            try await probe.startAndWaitForCancellation()
            return AgentToolResult(callID: invocation.call.id, content: "never")
        }
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("wait for me")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .toolCallDelta(id: "call-1", name: "wait", arguments: "{}"),
                        .finished(.toolCalls),
                    ]
                ]),
                tools: [tool],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "wait for me",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await probe.waitUntilStarted()
        #expect(await probe.started)
        await wait { conversation.workGroups.first?.run != nil }
        #expect(conversation.workGroups.first?.run != nil)

        conversation.stop()

        await wait { await probe.cancelled }
        #expect(await probe.cancelled)
        #expect(conversation.runState == .cancelled)
        #expect(!conversation.isStreaming)
        let stoppedRun = try #require(conversation.workGroups.first?.run)
        #expect(stoppedRun.state == .cancelled)
        #expect(stoppedRun.finishedAt != nil)
    }

    /// Tool-producing prose and its cards belong to one disclosure before the
    /// final answer, instead of being ordered by when provider events arrived.
    @Test
    func timelineInterleavesToolCardsWithTheMessagesTheyBelongTo() async {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("inspect")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .textDelta("Checking."),
                        .toolCallDelta(id: "call-1", name: "lookup", arguments: "{}"),
                        .finished(.toolCalls),
                    ],
                    [.textDelta("host-a is up"), .finished(.completed)],
                ]),
                tools: [
                    AnyAgentTool(
                        descriptor: AgentToolDescriptor(
                            name: "lookup", summary: "lookup",
                            inputSchema: .object([
                                "type": .string("object"), "properties": .object([:]),
                                "required": .array([]), "additionalProperties": .bool(false),
                            ]),
                            target: .local, approvalPolicy: .approve
                        )
                    ) { invocation, _ in
                        AgentToolResult(callID: invocation.call.id, content: "host-a")
                    }
                ],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)

        let kinds = conversation.timeline.map { item in
            switch item {
            case .message(let message): message.role == .user ? "user" : "assistant"
            case .tool: "tool"
            case .work: "work"
            case .command: "command"
            case .plan: "plan"
            case .compaction: "compaction"
            case .compactionActivity: "compaction-activity"
            case .failure: "failure"
            }
        }
        #expect(kinds == ["user", "work", "assistant"])
        let work = conversation.workGroups.first
        #expect(work?.items.count == 2)
        #expect(work?.run.state == .completed)
    }

    @Test
    func toolBatchPublishesAtomicallyAndStaysStableAcrossCompletion() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("run both")
        let runID = UUID()
        let start = Date()
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: start
                )))
        let descriptor = AgentToolDescriptor(
            name: "lookup", summary: "lookup", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve
        )
        let source = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [
                AgentToolCall(id: "first", name: "lookup", arguments: .object([:])),
                AgentToolCall(id: "second", name: "lookup", arguments: .object([:])),
            ],
            createdAt: start.addingTimeInterval(0.5)
        )
        conversation.handle(.messageFinished(source))
        let first = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(id: "first", name: "lookup", arguments: .object([:])),
            sourceMessageID: source.id,
            createdAt: start.addingTimeInterval(1)
        )
        let second = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(id: "second", name: "lookup", arguments: .object([:])),
            sourceMessageID: source.id,
            createdAt: start.addingTimeInterval(2)
        )
        conversation.handle(.toolProposed(first, descriptor))
        #expect(conversation.workGroups.isEmpty)
        conversation.handle(
            .toolFinished(
                first,
                AgentToolResult(
                    callID: first.call.id, content: "failed", isError: true
                )))
        #expect(conversation.workGroups.isEmpty)

        conversation.handle(.toolProposed(second, descriptor))
        guard case .tools(let live) = try #require(conversation.workGroups.first?.items.first)
        else {
            Issue.record("Two adjacent tools should form one live batch")
            return
        }
        #expect(live.cards.map(\.id) == [first.id, second.id])
        #expect(live.cards.map(\.state) == [.failed, .proposed])

        conversation.handle(
            .toolFinished(
                second,
                AgentToolResult(
                    callID: second.call.id, content: "ok"
                )))
        guard
            case .tools(let terminal) = try #require(
                conversation.workGroups.first?.items.first
            )
        else {
            Issue.record("A failed member must not split the completed batch")
            return
        }
        #expect(terminal.cards.map(\.state) == [.failed, .completed])
    }

    @Test
    func providerNativeToolsPublishAtomicallyWhenTheirTurnFinishes() throws {
        let conversation = ConversationModel()
        let runID = UUID()
        let source = AgentTranscriptMessage(role: .assistant)
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: source.createdAt
                )))
        conversation.handle(.messageStarted(source))
        let descriptor = AgentToolDescriptor(
            name: "web_search", summary: "search", inputSchema: .object([:]),
            target: .network, approvalPolicy: .approve
        )
        let invocations = ["first", "second"].map { id in
            AgentToolInvocation(
                runID: runID,
                call: AgentToolCall(
                    id: id, name: "web_search",
                    arguments: .object(["query": .string(id)])
                ),
                sourceMessageID: source.id
            )
        }
        for invocation in invocations {
            conversation.handle(.toolProposed(invocation, descriptor))
            conversation.handle(
                .toolFinished(
                    invocation,
                    AgentToolResult(
                        callID: invocation.call.id,
                        content: "[]",
                        metadata: [AgentToolResult.providerNativeKey: .bool(true)]
                    )))
            #expect(conversation.toolCards.isEmpty)
        }

        conversation.handle(.messageFinished(source))

        #expect(conversation.toolCards.map(\.id) == invocations.map(\.id))
        guard
            case .tools(let batch) = try #require(
                conversation.workGroups.first?.items.first
            )
        else {
            Issue.record("Expected one provider-native batch")
            return
        }
        #expect(batch.cards.map(\.state) == [.completed, .completed])
    }

    @Test
    func liveToolBatchReusesOnlyItsProviderTurnsReasoning() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("inspect both")
        let runID = UUID()
        let start = Date()
        let source = AgentTranscriptMessage(
            role: .assistant,
            reasoning: [AgentReasoningBlock(text: "**Compare** both hosts.\nThen verify them.")],
            toolCalls: ["first", "second"].map {
                AgentToolCall(id: $0, name: "lookup", arguments: .object([:]))
            },
            createdAt: start.addingTimeInterval(1)
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: start
                )))
        conversation.handle(.messageStarted(source))
        conversation.handle(.messageFinished(source))
        conversation.handle(.turnFinished(index: 0, stopReason: .toolCalls))

        let descriptor = AgentToolDescriptor(
            name: "lookup", summary: "lookup", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve
        )
        let invocations = ["first", "second"].enumerated().map { offset, callID in
            AgentToolInvocation(
                runID: runID,
                call: AgentToolCall(id: callID, name: "lookup", arguments: .object([:])),
                sourceMessageID: source.id,
                createdAt: start.addingTimeInterval(Double(offset + 2))
            )
        }
        for invocation in invocations {
            conversation.handle(.toolProposed(invocation, descriptor))
        }

        guard
            case .tools(let live) = try #require(
                conversation.workGroups.first?.items.first
            )
        else {
            Issue.record("Expected a live tool batch")
            return
        }
        #expect(live.runID == runID)
        #expect(live.reasoning?.sourceMessageID == source.id)
        #expect(live.reasoning?.markdown == "**Compare** both hosts.\nThen verify them.")

        for invocation in invocations {
            conversation.handle(
                .toolFinished(
                    invocation,
                    AgentToolResult(
                        callID: invocation.call.id, content: "ok"
                    )))
        }
        guard
            case .tools(let terminal) = try #require(
                conversation.workGroups.first?.items.first
            )
        else {
            Issue.record("Expected the completed tools to remain batched")
            return
        }
        #expect(terminal.reasoning == nil)
    }

    @Test
    func liveToolBatchOwnsCurrentlyStreamingReasoningWithoutADuplicateRow() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("inspect both")
        let runID = UUID()
        let start = Date()
        let reasoning = AgentReasoningBlock(text: "Compare both hosts.")
        let source = AgentTranscriptMessage(
            role: .assistant, reasoning: [reasoning],
            toolCalls: ["first", "second"].map {
                AgentToolCall(id: $0, name: "lookup", arguments: .object([:]))
            },
            createdAt: start.addingTimeInterval(1)
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: start
                )))
        conversation.handle(.messageStarted(source))
        conversation.handle(
            .reasoningDelta(
                messageID: source.id, text: reasoning.text
            ))
        conversation.handle(.messageFinished(source))

        let descriptor = AgentToolDescriptor(
            name: "lookup", summary: "lookup", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve
        )
        for (offset, call) in source.toolCalls.enumerated() {
            conversation.handle(
                .toolProposed(
                    AgentToolInvocation(
                        runID: runID, call: call, sourceMessageID: source.id,
                        createdAt: start.addingTimeInterval(Double(offset + 2))
                    ), descriptor))
        }

        let overlappingGroup = try #require(conversation.workGroups.first)
        #expect(
            !overlappingGroup.items.contains { item in
                guard case .reasoning = item else { return false }
                return true
            })
        guard
            case .tools(let overlappingBatch) = try #require(
                overlappingGroup.items.first(where: {
                    if case .tools = $0 { return true }
                    return false
                })
            )
        else {
            Issue.record("Expected a live tool batch")
            return
        }
        #expect(overlappingBatch.reasoning?.markdown == reasoning.text)

        conversation.handle(.turnFinished(index: 0, stopReason: .toolCalls))
        let settledGroup = try #require(conversation.workGroups.first)
        #expect(
            !settledGroup.items.contains { item in
                guard case .reasoning = item else { return false }
                return true
            })
        guard
            case .tools(let settledBatch) = try #require(
                settledGroup.items.first(where: {
                    if case .tools = $0 { return true }
                    return false
                })
            )
        else {
            Issue.record("Expected the live tool batch to remain")
            return
        }
        #expect(settledBatch.reasoning?.markdown == reasoning.text)
    }

    @Test
    func directAnswerDoesNotCreateAWorkGroup() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("hello")
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    role: .assistant, text: "Hello!"
                )))

        #expect(conversation.workGroups.isEmpty)
        #expect(conversation.timeline.count == 2)
    }

    @Test
    func finishedReasoningOnlyAnswerLeavesNoWorkedHistory() async {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("compare")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .reasoningDelta("Compared the two configurations."),
                        .textDelta("Use the second configuration."),
                        .finished(.completed),
                    ]
                ]),
                tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "compare",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)

        let order = conversation.timeline.map { item in
            switch item {
            case .message(let message): return message.role == .user ? "user" : "assistant"
            case .work: return "work"
            default: return "other"
            }
        }
        #expect(order == ["user", "assistant"])
        #expect(conversation.workGroups.isEmpty)
        #expect(conversation.messages.last?.text == "Use the second configuration.")
        #expect(
            conversation.messages.last?.reasoning.map(\.text)
                == ["Compared the two configurations."])
    }

    @Test
    func liveReasoningReplacesTheGenericWorkingIndicator() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("think")
        let runID = UUID()
        let startedAt = Date()
        let assistant = AgentTranscriptMessage(
            role: .assistant, createdAt: startedAt.addingTimeInterval(1)
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: startedAt
                )))
        conversation.handle(.messageStarted(assistant))

        let placeholderGroup = try #require(conversation.workGroups.first)
        guard case .message(let placeholder) = try #require(placeholderGroup.items.first) else {
            Issue.record("Expected Working in the future reasoning slot")
            return
        }
        #expect(placeholder.id == assistant.id)
        #expect(placeholder.text.isEmpty)
        #expect(
            conversation.timeline.compactMap { item -> UUID? in
                guard case .message(let message) = item, message.role == .assistant else {
                    return nil
                }
                return message.id
            }.isEmpty)

        conversation.handle(
            .reasoningDelta(
                messageID: assistant.id, text: "Evaluating the request."
            ))

        let group = try #require(conversation.workGroups.first)
        #expect(group.id == placeholderGroup.id)
        guard case .reasoning(let block) = try #require(group.items.first) else {
            Issue.record("Expected live reasoning in Worked")
            return
        }
        #expect(group.activeReasoningBlockID == block.id)
        let visibleAssistantRows = conversation.timeline.compactMap { item -> ChatMessage? in
            guard case .message(let message) = item, message.role == .assistant else {
                return nil
            }
            return message
        }
        #expect(visibleAssistantRows.isEmpty)

        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: assistant.id, role: .assistant, reasoning: [block],
                    createdAt: assistant.createdAt
                )))
        conversation.handle(.turnFinished(index: 0, stopReason: .toolCalls))
        #expect(conversation.workGroups.isEmpty)

        // A new model turn gets its own ordinary Working placeholder until it
        // produces reasoning. The previous turn's reasoning never returns.
        conversation.handle(.turnStarted(index: 1))
        let continuation = AgentTranscriptMessage(
            role: .assistant, createdAt: startedAt.addingTimeInterval(2)
        )
        conversation.handle(.messageStarted(continuation))
        let continuationGroup = try #require(conversation.workGroups.first)
        let placeholderIDs = continuationGroup.items.compactMap { item -> UUID? in
            guard case .message(let message) = item else { return nil }
            return message.id
        }
        #expect(placeholderIDs == [continuation.id])
        #expect(
            conversation.timeline.compactMap { item -> UUID? in
                guard case .message(let message) = item, message.role == .assistant else {
                    return nil
                }
                return message.id
            }.isEmpty)

        conversation.handle(.messageDelta(messageID: continuation.id, text: "Answer"))
        #expect(conversation.workGroups.first?.activeReasoningBlockID == nil)
    }

    @Test
    func finishedReasoningDisappearsWhileToolsMergeAcrossProviderTurns() async throws {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("inspect both")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .reasoningDelta("Choose both checks."),
                        .toolCallDelta(id: "call-1", name: "lookup", arguments: "{}"),
                        .toolCallDelta(id: "call-2", name: "lookup", arguments: "{}"),
                        .finished(.toolCalls),
                    ],
                    [
                        .reasoningDelta("Verify the combined result."),
                        .toolCallDelta(id: "call-3", name: "lookup", arguments: "{}"),
                        .finished(.toolCalls),
                    ],
                    [
                        .reasoningDelta("Compare all results."),
                        .textDelta("Both checks passed."),
                        .finished(.completed),
                    ],
                ]),
                tools: [
                    AnyAgentTool(
                        descriptor: AgentToolDescriptor(
                            name: "lookup", summary: "lookup",
                            inputSchema: .object([
                                "type": .string("object"), "properties": .object([:]),
                                "required": .array([]), "additionalProperties": .bool(false),
                            ]),
                            target: .local, approvalPolicy: .approve
                        )
                    ) { invocation, _ in
                        AgentToolResult(callID: invocation.call.id, content: "ok")
                    }
                ],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect both",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)

        let group = try #require(conversation.workGroups.first)
        #expect(conversation.workGroups.count == 1)
        let kinds = group.items.map { item in
            switch item {
            case .reasoning(let block): return "reasoning:\(block.text)"
            case .message(let message): return "message:\(message.text)"
            case .tool(let card): return "tool:\(card.invocation.call.id)"
            case .tools(let batch):
                return "tools:\(batch.cards.map(\.invocation.call.id).joined(separator: ","))"
            }
        }
        #expect(kinds == ["tools:call-1,call-2,call-3"])
        #expect(
            conversation.timeline.compactMap { item in
                if case .work = item { return "work" }
                return nil
            } == ["work"])
    }

    @Test
    func providerTurnsWithoutReasoningShareOneRunScopedToolBatch() async throws {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        conversation.appendUserTurn("inspect four")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .toolCallDelta(id: "call-1", name: "lookup", arguments: "{}"),
                        .toolCallDelta(id: "call-2", name: "lookup", arguments: "{}"),
                        .finished(.toolCalls),
                    ],
                    [
                        .toolCallDelta(id: "call-3", name: "lookup", arguments: "{}"),
                        .toolCallDelta(id: "call-4", name: "lookup", arguments: "{}"),
                        .finished(.toolCalls),
                    ],
                    [.textDelta("Done."), .finished(.completed)],
                ]),
                tools: [
                    AnyAgentTool(
                        descriptor: AgentToolDescriptor(
                            name: "lookup", summary: "lookup",
                            inputSchema: .object([
                                "type": .string("object"), "properties": .object([:]),
                                "required": .array([]), "additionalProperties": .bool(false),
                            ]),
                            target: .local, approvalPolicy: .approve
                        )
                    ) { invocation, _ in
                        AgentToolResult(callID: invocation.call.id, content: "ok")
                    }
                ],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect four",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)

        let group = try #require(conversation.workGroups.first)
        let batches: [[String]] = group.items.map { item -> [String] in
            switch item {
            case .tools(let batch): batch.cards.map(\.invocation.call.id)
            case .tool(let card): [card.invocation.call.id]
            case .reasoning, .message: []
            }
        }.filter { !$0.isEmpty }
        #expect(batches == [["call-1", "call-2", "call-3", "call-4"]])
    }

    @Test
    func terminalSuggestionStaysIndependentAndBreaksAdjacentToolBatches() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("prepare")
        let runID = UUID()
        let sourceMessageID = UUID()
        let startedAt = Date()
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: startedAt
                )))
        let calls = [
            "lookup", "lookup", "terminal_suggest", "lookup", "lookup",
        ].enumerated().map { offset, name in
            AgentToolCall(id: "call-\(offset)", name: name, arguments: .object([:]))
        }
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: sourceMessageID,
                    role: .assistant,
                    toolCalls: calls,
                    createdAt: startedAt
                )))
        let lookup = AgentToolDescriptor(
            name: "lookup", summary: "lookup", inputSchema: .object([:]),
            target: .local, approvalPolicy: .approve
        )
        let suggestion = AnyAgentTool(TerminalSuggestTool()).descriptor
        #expect(suggestion.presentation?.groupsWithAdjacentTools == false)
        for (offset, name) in [
            "lookup", "lookup", "terminal_suggest", "lookup", "lookup",
        ].enumerated() {
            let invocation = AgentToolInvocation(
                runID: runID,
                call: AgentToolCall(id: "call-\(offset)", name: name, arguments: .object([:])),
                sourceMessageID: sourceMessageID,
                createdAt: startedAt.addingTimeInterval(Double(offset + 1))
            )
            conversation.handle(
                .toolProposed(
                    invocation, name == "terminal_suggest" ? suggestion : lookup
                ))
        }

        let group = try #require(conversation.workGroups.first)
        let items = group.items
        let groups = items.map { item -> [String] in
            switch item {
            case .tools(let batch): batch.cards.map(\.descriptor.name)
            case .tool(let card): [card.descriptor.name]
            case .reasoning, .message: []
            }
        }.filter { !$0.isEmpty }
        #expect(
            groups == [
                ["lookup", "lookup", "lookup", "lookup"], ["terminal_suggest"],
            ])
    }

    @Test
    func completedLegacyTerminalSuggestionIsPromotedWithoutItsExplanation() throws {
        let conversation = ConversationModel()
        let runID = UUID()
        let createdAt = Date(timeIntervalSince1970: 2_000)
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID,
                    state: .running,
                    startedAt: createdAt
                )))
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(
                id: "suggest-command",
                name: "terminal_suggest",
                arguments: .object([
                    "command": .string("pwd"),
                    "explanation": .string("Show the current directory."),
                ])
            ),
            createdAt: createdAt
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AnyAgentTool(TerminalSuggestTool()).descriptor
            ))
        conversation.handle(
            .toolFinished(
                invocation,
                AgentToolResult(callID: invocation.call.id, content: "{}")
            ))

        #expect(conversation.workGroups.isEmpty)
        let item = try #require(conversation.timeline.first)
        guard case .command(let command) = item else {
            Issue.record("Expected a promoted command card, got \(item)")
            return
        }
        #expect(command.id == invocation.id)
        #expect(command.command == "pwd")
        #expect(command.createdAt == createdAt)
    }

    @Test
    func restoredReasoningStaysPersistedButOutOfWorked() throws {
        let conversationID = UUID()
        let runID = UUID()
        let createdAt = Date(timeIntervalSince1970: 2_000)
        let reasoning = AgentReasoningBlock(
            text: "Restored provider summary.", createdAt: createdAt
        )
        let assistant = AgentTranscriptMessage(
            role: .assistant, text: "Restored answer", reasoning: [reasoning],
            createdAt: createdAt
        )
        let store = AssistantConversationStore()
        store.restore([
            StoredAgentConversation(
                id: conversationID, messages: [assistant],
                messageRunIDs: [assistant.id: runID],
                runs: [
                    AgentRunSummary(
                        id: runID, state: .completed, startedAt: createdAt,
                        finishedAt: createdAt.addingTimeInterval(1)
                    )
                ],
                lastRunState: .completed
            )
        ])

        let restored = try #require(store.conversation(id: conversationID))
        #expect(restored.messages.first?.reasoning == [reasoning])
        #expect(restored.workGroups.isEmpty)
    }

    @Test
    func stoppedDirectAnswerShowsItsStoppedDurationAfterThePartialAnswer() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("Explain")
        let runID = UUID()
        let start = Date()
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: start
                )))
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    role: .assistant, text: "Partial answer",
                    createdAt: start.addingTimeInterval(1)
                )))
        conversation.handle(
            .runFinished(
                AgentRunSummary(
                    id: runID, state: .cancelled, startedAt: start,
                    finishedAt: start.addingTimeInterval(62)
                )))

        let order = conversation.timeline.map { item in
            switch item {
            case .message(let message): return message.role == .user ? "user" : "assistant"
            case .work: return "work"
            default: return "other"
            }
        }
        #expect(order == ["user", "assistant", "work"])
        #expect(conversation.workGroups.first?.items.isEmpty == true)
        #expect(conversation.workGroups.first?.appearsAfterAnswer == true)
        let run = conversation.workGroups.first?.run
        #expect(
            run.map {
                AgentWorkPresentation.title(
                    for: $0.state, from: $0.startedAt, to: $0.finishedAt ?? start,
                    locale: Locale(identifier: "en")
                )
            } == "You stopped after 1m 2s")
    }

    @Test
    func providerSearchReportedAfterTextAppearsAfterTheAnswerAndExpanded() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("search")
        let runID = UUID()
        let startedAt = Date()
        let answer = AgentTranscriptMessage(
            role: .assistant, text: "The answer", createdAt: startedAt.addingTimeInterval(1)
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: startedAt
                )))
        conversation.handle(.messageStarted(answer))
        conversation.handle(.messageFinished(answer))

        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(
                id: "provider-search", name: "web_search",
                arguments: .object(["query": .string("search")])
            ),
            sourceMessageID: answer.id,
            createdAt: startedAt.addingTimeInterval(2)
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "web_search", summary: "Provider search",
                    inputSchema: .object([:]), target: .network, approvalPolicy: .approve
                )))
        conversation.handle(
            .toolFinished(
                invocation,
                AgentToolResult(
                    callID: invocation.call.id, content: "[]",
                    metadata: [AgentToolResult.providerNativeKey: .bool(true)]
                )))
        conversation.handle(
            .runFinished(
                AgentRunSummary(
                    id: runID, state: .completed, startedAt: startedAt,
                    finishedAt: startedAt.addingTimeInterval(3)
                )))

        let order = conversation.timeline.map { item in
            switch item {
            case .message(let message): return message.role == .user ? "user" : "assistant"
            case .work: return "work"
            default: return "other"
            }
        }
        #expect(order == ["user", "assistant", "work"])
        #expect(conversation.workGroups.first?.items.count == 1)
        #expect(conversation.workGroups.first?.appearsAfterAnswer == true)
        #expect(
            AgentWorkPresentation.isExpandedByDefault(
                for: .completed, appearsAfterAnswer: true
            ))
    }

    @Test
    func workDurationUsesAtMostTwoUnitsAndSuccessfulRunsCollapseByDefault() {
        let start = Date(timeIntervalSince1970: 1_000)
        let en = Locale(identifier: "en")
        let zh = Locale(identifier: "zh-Hans")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(42), locale: en
            ) == "42s")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(68), locale: en
            ) == "1m 8s")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(4_320), locale: en
            ) == "1h 12m")
        #expect(!AgentWorkPresentation.isExpandedByDefault(for: .completed))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .running))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .waitingForUser))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .failed))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .cancelled))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .interrupted))
        #expect(AgentWorkPresentation.isExpandedByDefault(for: .running, isCompact: true))
        #expect(
            AgentWorkPresentation.isExpandedByDefault(
                for: .waitingForUser, appearsAfterAnswer: true, isCompact: true
            ))
        #expect(
            AgentWorkPresentation.title(
                for: .running, from: start, to: start.addingTimeInterval(68), locale: en
            ) == "Working for 1m 8s")
        #expect(
            AgentWorkPresentation.title(
                for: .completed, from: start, to: start.addingTimeInterval(68), locale: en
            ) == "Worked for 1m 8s")
        #expect(
            AgentWorkPresentation.title(
                for: .cancelled, from: start, to: start.addingTimeInterval(62), locale: en
            ) == "You stopped after 1m 2s")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(42), locale: zh
            ) == "42秒")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(68), locale: zh
            ) == "1分钟8秒")
        #expect(
            AgentWorkPresentation.duration(
                from: start, to: start.addingTimeInterval(4_320), locale: zh
            ) == "1小时12分钟")
        #expect(
            AgentWorkPresentation.title(
                for: .running, from: start, to: start.addingTimeInterval(68), locale: zh
            ) == "已工作1分钟8秒")
        // Chinese uses one phrase where English distinguishes "Working for"
        // from "Worked for". The running and finished rows are already told
        // apart by the spinner and by whether the disclosure is folded, so the
        // tense the English carries is not load-bearing here.
        #expect(
            AgentWorkPresentation.title(
                for: .completed, from: start, to: start.addingTimeInterval(68), locale: zh
            ) == "已工作1分钟8秒")
        #expect(
            AgentWorkPresentation.title(
                for: .cancelled, from: start, to: start.addingTimeInterval(62), locale: zh
            ) == "你在1分钟2秒后停止了")
    }

    /// A turn that only called tools has nothing to say, and an empty bubble
    /// reads as the model having said nothing at all.
    @Test
    func aSilentToolOnlyTurnDoesNotLeaveAnEmptyBubble() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("go")
        let started = AgentTranscriptMessage(role: .assistant)
        let id = started.id
        conversation.handle(.messageStarted(started))
        #expect(conversation.timeline.count == 2, "a streaming turn still shows progress")

        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    id: id, role: .assistant, text: "",
                    toolCalls: [AgentToolCall(id: "c", name: "lookup", arguments: .object([:]))]
                )))

        #expect(conversation.timeline.count == 1)
        #expect(conversation.messages.count == 2, "the turn is still in the history")
    }

    /// The runtime held the conversation through both its approval broker and
    /// its interaction handler, while the conversation held the runtime — so
    /// every chat that ever ran an agent stayed alive for the whole session.
    @Test
    func aFinishedRunDoesNotKeepItsConversationAlive() async {
        weak var leaked: ConversationModel?
        do {
            let conversation = ConversationModel()
            let repository = InMemoryAgentRunRepository()
            leaked = conversation
            conversation.appendUserTurn("hello")
            conversation.start(
                runtime: AgentRuntime(
                    model: ImmediateConversationAgentModel(turns: [
                        [
                            .textDelta("hi"), .finished(.completed),
                        ]
                    ]),
                    tools: [],
                    approval: AgentApprovalBroker(
                        reviewer: nil,
                        manualApproval: { [weak conversation] request in
                            guard let conversation else { return .deny("gone") }
                            return await conversation.requestApproval(request)
                        }
                    ),
                    repository: repository,
                    userInteraction: WeakAgentUserInteraction(conversation)
                ),
                request: AgentRunRequest(
                    conversationID: conversation.id, prompt: "hello",
                    permissionMode: .askForApproval
                ),
                repository: repository
            )
            await waitForTerminal(conversation)
        }
        // The event task holds the conversation until the stream ends; give the
        // runloop a turn to release it.
        await wait { leaked == nil }
        #expect(leaked == nil)
    }

    // MARK: - Attachments

    /// An attachment used to be a label for a payload that travelled separately
    /// — pasted into the draft — so what the chip claimed and what was uploaded
    /// were two different things.
    @Test
    func anAttachmentIsSentWithTheTurnItWasAttachedTo() {
        let conversation = ConversationModel()
        conversation.attach(
            ContextChip(
                kind: .output, label: "Connection error", content: "ssh: connect refused"
            ))

        let sent = conversation.appendUserTurn("What should I check?")

        #expect(sent.hasPrefix("What should I check?"))
        #expect(sent.contains(#"<output label="Connection error">"#))
        #expect(sent.contains("ssh: connect refused"))
        // The model keeps the payload, while the bubble renders only what the
        // user typed so a large extraction never becomes a Markdown tree.
        #expect(conversation.messages.last?.text == "What should I check?")
        #expect(conversation.transcript.last?.text == sent)
    }

    @Test
    func pastedTextStaysOutOfTheVisibleBubble() {
        let conversation = ConversationModel()
        let pasted = String(repeating: "large pasted context\n", count: 2_000)
        conversation.attach(ContextChip(kind: .pastedText, label: "Pasted text", content: pasted))

        let sent = conversation.appendUserTurn("Summarize it")

        #expect(sent.contains(pasted))
        #expect(conversation.transcript.last?.text.contains(pasted) == true)
        #expect(conversation.messages.last?.text == "Summarize it")
        #expect(conversation.messages.last?.contextChips.map(\.label) == ["Pasted text"])
    }

    @Test
    func restoredAttachmentPayloadStaysOutOfTheVisibleBubble() {
        let payload = String(repeating: "PDF extraction\n", count: 10_000)
        let modelText = "Review this\n\n<file label=\"manual.pdf\">\n\(payload)\n</file>"
        let message = AgentTranscriptMessage(role: .user, text: modelText)
        let store = AssistantConversationStore()

        store.restore([
            StoredAgentConversation(
                id: UUID(), messages: [message], lastRunState: .completed
            )
        ])

        #expect(store.conversations.first?.messages.first?.text == "Review this")
        #expect(
            store.conversations.first?.messages.first?.contextChips.map(\.label) == [
                "manual.pdf"
            ])
        #expect(store.conversations.first?.transcript.first?.text == modelText)
    }

    /// Consumed, not kept: the payload is in the transcript from here on, and
    /// re-uploading it every turn is the bill the user's own key pays.
    @Test
    func anAttachmentIsConsumedByTheTurnAndNotResent() {
        let conversation = ConversationModel()
        conversation.attach(ContextChip(kind: .file, label: "nginx.conf", content: "worker;"))

        conversation.appendUserTurn("first")
        #expect(conversation.composer.attachments.isEmpty)

        let second = conversation.appendUserTurn("second")
        #expect(second == "second")
    }

    @Test
    func detachingRemovesTheChipAndItsPayload() {
        let conversation = ConversationModel()
        let chip = ContextChip(kind: .selection, label: "Selection", content: "df -h")
        conversation.attach(chip)
        conversation.attach(chip)

        #expect(conversation.composer.attachments.count == 1, "the same attachment twice is once")

        conversation.detach(chip.id)

        #expect(conversation.composer.attachments.isEmpty)
        #expect(conversation.appendUserTurn("hello") == "hello")
    }

    // MARK: - Titling

    @Test
    func aFinishedRunNotifiesItsOwnerExactlyOnce() async {
        let conversation = ConversationModel()
        let repository = InMemoryAgentRunRepository()
        var finishes = 0
        conversation.runDidFinish = { finishes += 1 }
        conversation.appendUserTurn("hello")
        conversation.start(
            runtime: AgentRuntime(
                model: ImmediateConversationAgentModel(turns: [
                    [
                        .textDelta("hi"), .finished(.completed),
                    ]
                ]),
                tools: [],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow }),
                repository: repository
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "hello",
                permissionMode: .askForApproval
            ),
            repository: repository
        )
        await waitForTerminal(conversation)
        await wait { finishes > 0 }

        #expect(finishes == 1)
    }

    @Test
    func thereIsNothingToSummarizeUntilTheModelHasAnswered() {
        let conversation = ConversationModel()
        #expect(AppModel.titleContext(for: conversation) == nil)

        conversation.appendUserTurn("Root is at 99%")
        #expect(AppModel.titleContext(for: conversation) == nil)

        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(role: .assistant, text: "Start with du -sh /var/*.")
            ))

        let context = AppModel.titleContext(for: conversation)
        #expect(context?.firstUserMessage == "Root is at 99%")
        #expect(context?.firstAssistantMessage == "Start with du -sh /var/*.")
    }

    @Test
    func aConversationThatAlreadyHasATitleIsNotSummarizedAgain() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("Root is at 99%")
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(role: .assistant, text: "Start with du.")
            ))
        #expect(AppModel.titleContext(for: conversation) != nil)

        conversation.title = "Root volume filling up"

        #expect(AppModel.titleContext(for: conversation) == nil)
        #expect(conversation.derivedTitle == "Root volume filling up")
    }

    private func beginStreamingConversation() -> (
        conversation: ConversationModel, runID: UUID, assistant: AgentTranscriptMessage
    ) {
        let conversation = ConversationModel()
        conversation.appendUserTurn("Explain")
        let runID = UUID()
        // Keep both event stamps before the stop that follows in each test,
        // matching the runtime's monotonic event order.
        let startedAt = Date().addingTimeInterval(-2)
        let assistant = AgentTranscriptMessage(
            role: .assistant, createdAt: startedAt.addingTimeInterval(1)
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: startedAt
                )))
        conversation.handle(.runState(.running))
        conversation.handle(.messageStarted(assistant))
        return (conversation, runID, assistant)
    }

    private func timelineKind(_ item: TimelineItem) -> String {
        switch item {
        case .message(let message): return message.role == .user ? "user" : "assistant"
        case .work: return "work"
        default: return "other"
        }
    }

    @Test
    func derivedTitleFallsBackToTheOpeningLineUntilASummaryArrives() {
        let conversation = ConversationModel()
        #expect(conversation.derivedTitle == "New Chat")

        conversation.appendUserTurn("Root is at 99%\nand climbing")
        #expect(conversation.derivedTitle == "Root is at 99%")

        conversation.title = "Disk pressure on root"
        #expect(conversation.derivedTitle == "Disk pressure on root")
    }

    @Test
    func editingAUserTurnTruncatesTheVisibleAndModelHistoryAndKeepsAttachments() throws {
        let image = AgentImageAttachment(
            label: "screen.png", mimeType: "image/png", data: Data([1, 2, 3]),
            pixelWidth: 10, pixelHeight: 10
        )
        let conversation = ConversationModel()
        conversation.attach(ContextChip(kind: .image, label: image.label, image: image))
        let opening = conversation.appendUserTurnContent("Original")
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    role: .assistant, text: "First answer", createdAt: .now.addingTimeInterval(1)
                )))
        _ = conversation.appendUserTurnContent("Follow-up")
        conversation.handle(
            .messageFinished(
                AgentTranscriptMessage(
                    role: .assistant, text: "Second answer", createdAt: .now.addingTimeInterval(2)
                )))

        let replacement = try #require(
            conversation.editUserMessage(opening.id, authoredText: "Edited")
        )

        #expect(conversation.messages.map(\.text) == ["Edited"])
        #expect(conversation.transcript.count == 1)
        #expect(conversation.transcript.first?.authoredText == "Edited")
        #expect(replacement.images == [image])
    }

    @Test
    func onlyAssistantMessagesInReplayableHistoryCanBeForked() throws {
        let conversation = ConversationModel()
        let user = conversation.appendUserTurnContent("Question")
        let assistant = AgentTranscriptMessage(role: .assistant, text: "Answer")
        conversation.handle(.messageFinished(assistant))

        #expect(!conversation.canForkAssistantMessage(user.id))
        #expect(conversation.canForkAssistantMessage(assistant.id))
        let fork = try #require(conversation.forked(throughAssistantMessage: assistant.id))
        #expect(fork.id != conversation.id)
        #expect(fork.messages.map(\.text) == ["Question", "Answer"])
        #expect(Set(fork.transcript.map(\.id)).isDisjoint(with: conversation.transcript.map(\.id)))
        #expect(fork.customTitle == "Question (1)")
    }

    @Test
    func forkRemapsWorkRunAndSourceMessageIDs() throws {
        let conversation = ConversationModel()
        conversation.appendUserTurn("Question")
        let runID = UUID()
        let startedAt = Date()
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: startedAt
                )))
        let process = AgentTranscriptMessage(
            role: .assistant, text: "Checking",
            toolCalls: [AgentToolCall(id: "call", name: "lookup", arguments: .object([:]))],
            createdAt: startedAt.addingTimeInterval(1)
        )
        conversation.handle(.messageFinished(process))
        let invocation = AgentToolInvocation(
            runID: runID, call: process.toolCalls[0], sourceMessageID: process.id,
            createdAt: startedAt.addingTimeInterval(2)
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "Lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))
        conversation.handle(
            .toolFinished(
                invocation, AgentToolResult(callID: "call", content: "result")
            ))
        let final = AgentTranscriptMessage(
            role: .assistant, text: "Answer", createdAt: startedAt.addingTimeInterval(3)
        )
        conversation.handle(.messageFinished(final))
        conversation.handle(
            .runFinished(
                AgentRunSummary(
                    id: runID, state: .completed, startedAt: startedAt,
                    finishedAt: startedAt.addingTimeInterval(4)
                )))

        let fork = try #require(conversation.forked(throughAssistantMessage: final.id))
        let forkRunIDs = Set(fork.runSummaries.keys)
        let clonedProcess = try #require(
            fork.transcript.first {
                $0.role == .assistant && !$0.toolCalls.isEmpty
            })
        let clonedCard = try #require(fork.toolCards.first)
        #expect(!forkRunIDs.contains(runID))
        #expect(forkRunIDs.contains(clonedCard.invocation.runID))
        #expect(clonedCard.invocation.sourceMessageID == clonedProcess.id)
        #expect(Set(fork.messageRunIDs.values).isSubset(of: forkRunIDs))
    }

    @Test
    func editingAUserTurnWithDownstreamToolActivityIsRejectedWithoutChangingHistory() {
        let conversation = ConversationModel()
        let user = conversation.appendUserTurnContent("Question")
        let runID = UUID()
        let process = AgentTranscriptMessage(
            role: .assistant, text: "Checking",
            toolCalls: [AgentToolCall(id: "call", name: "lookup", arguments: .object([:]))]
        )
        conversation.handle(
            .runStarted(
                AgentRunSummary(
                    id: runID, state: .running, startedAt: .now
                )))
        conversation.handle(.messageFinished(process))
        let invocation = AgentToolInvocation(
            runID: runID, call: process.toolCalls[0], sourceMessageID: process.id
        )
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: "lookup", summary: "Lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve
                )))
        #expect(conversation.workGroups.count == 1)

        #expect(!conversation.canEditUserMessage(user.id))
        #expect(conversation.editUserMessage(user.id, authoredText: "Edited") == nil)

        #expect(conversation.workGroups.count == 1)
        #expect(conversation.toolCards.map(\.invocation.id) == [invocation.id])
        #expect(conversation.runSummaries.count == 1)
        #expect(conversation.runSummaries[runID] != nil)
        #expect(conversation.transcript.map(\.id) == [user.id, process.id])
    }

    @Test(arguments: [
        AgentToolCard.State.proposed, .waitingForApproval, .waitingForUser, .reviewing,
        .running, .completed, .denied, .failed, .interrupted,
    ])
    func editEligibilityUsesToolOwnershipForEveryLifecycleState(_ state: AgentToolCard.State) {
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        let runID = UUID()
        let opening = AgentTranscriptMessage(role: .user, text: "Opening", createdAt: instant)
        let process = AgentTranscriptMessage(role: .assistant, text: "Checking", createdAt: instant)
        let later = AgentTranscriptMessage(role: .user, text: "Later", createdAt: instant)
        let answer = AgentTranscriptMessage(role: .assistant, text: "Answer", createdAt: instant)
        let transcript = [opening, process, later, answer]
        let conversation = ConversationModel(
            messages: transcript.map {
                ChatMessage(id: $0.id, role: $0.role == .user ? .user : .assistant, text: $0.text)
            }, transcript: transcript, runState: .completed,
            messageRunIDs: Dictionary(uniqueKeysWithValues: transcript.map { ($0.id, runID) }),
            runs: [AgentRunSummary(id: runID, state: .completed, startedAt: instant)])
        conversation.toolCards = [
            AgentToolCard(
                invocation: AgentToolInvocation(
                    runID: runID, call: AgentToolCall(id: "read", name: "lookup", arguments: .object([:])),
                    sourceMessageID: process.id, createdAt: instant.addingTimeInterval(-60)),
                descriptor: AgentToolDescriptor(
                    name: "lookup", summary: "Read-only lookup", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve), state: state)
        ]

        #expect(!conversation.canEditUserMessage(opening.id))
        #expect(conversation.canEditUserMessage(later.id))
    }

    @Test
    func editingSteeringKeepsCompactedSameRunPrefixAndLegacyToolOwnership() throws {
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        let runID = UUID()
        let opening = AgentTranscriptMessage(
            role: .user, text: "Opening", authoredText: "Opening", createdAt: instant)
        let call = AgentToolCall(id: "prefix-call", name: "inspect", arguments: .object([:]))
        let firstReply = AgentTranscriptMessage(
            role: .assistant, text: "First reply", toolCalls: [call], createdAt: instant)
        let steering = AgentTranscriptMessage(
            role: .user, text: "Steer", authoredText: "Steer", createdAt: instant)
        let secondReply = AgentTranscriptMessage(
            role: .assistant, text: "Second reply", createdAt: instant)
        let keptCompaction = AgentCompactionRecord(
            compactedThroughMessageID: firstReply.id, sequence: 0, summary: "Earlier context",
            summarizedTokens: 10, keptTokens: 2, displayAnchor: instant)
        let removedCompaction = AgentCompactionRecord(
            compactedThroughMessageID: secondReply.id, sequence: 1, summary: "Later context",
            summarizedTokens: 12, keptTokens: 2, displayAnchor: instant)
        let conversation = ConversationModel(
            messages: [
                ChatMessage(id: opening.id, role: .user, text: opening.text, createdAt: instant),
                ChatMessage(id: firstReply.id, role: .assistant, text: firstReply.text, createdAt: instant),
                ChatMessage(id: steering.id, role: .user, text: steering.text, createdAt: instant),
                ChatMessage(id: secondReply.id, role: .assistant, text: secondReply.text, createdAt: instant),
            ],
            transcript: [steering, secondReply], runState: .failed,
            messageRunIDs: [
                opening.id: runID, firstReply.id: runID, steering.id: runID, secondReply.id: runID,
            ],
            runs: [
                AgentRunSummary(
                    id: runID, state: .failed, startedAt: instant,
                    finishedAt: instant, failure: "old failure")
            ],
            compactionRecords: [keptCompaction, removedCompaction])
        conversation.title = "Keep this title"
        let invocation = AgentToolInvocation(
            runID: runID, call: call, sourceMessageID: firstReply.id,
            createdAt: instant.addingTimeInterval(1))
        conversation.handle(
            .toolProposed(
                invocation,
                AgentToolDescriptor(
                    name: call.name, summary: "Inspect", inputSchema: .object([:]),
                    target: .local, approvalPolicy: .approve)))
        conversation.handle(
            .planPresented(
                AgentPlan(
                    title: "Same-time plan", body: "Must be removed", scratchPath: "/tmp/plan.md",
                    createdAt: instant)))

        let replacement = try #require(
            conversation.editUserMessage(steering.id, authoredText: "Replacement"))

        #expect(conversation.messages.map(\.text) == ["Opening", "First reply", "Replacement"])
        #expect(conversation.transcript.map(\.text) == ["Replacement"])
        #expect(conversation.toolCards.map(\.id) == [invocation.id])
        #expect(conversation.compactionRecords == [keptCompaction])
        #expect(conversation.compactions.map(\.id) == [keptCompaction.id])
        #expect(conversation.plans.isEmpty)
        #expect(conversation.title == "Keep this title")
        let prefix = try #require(conversation.runSummaries[runID])
        #expect(prefix.state == .completed)
        #expect(prefix.finishedAt == instant)
        #expect(prefix.failure == nil)
        #expect(conversation.messageRunIDs[opening.id] == runID)
        #expect(conversation.messageRunIDs[firstReply.id] == runID)
        #expect(conversation.messageRunIDs[replacement.id] == replacement.id)

        let stagingStartedAt = try #require(conversation.runSummaries[replacement.id]).startedAt
        let realRunID = UUID()
        conversation.handle(
            .runStarted(
                AgentRunSummary(id: realRunID, state: .running, startedAt: instant)))
        #expect(conversation.messageRunIDs[replacement.id] == realRunID)
        #expect(conversation.runSummaries[realRunID]?.startedAt == stagingStartedAt)
        conversation.handle(
            .runFinished(
                AgentRunSummary(
                    id: realRunID, state: .completed, startedAt: instant,
                    finishedAt: instant)))
        #expect(conversation.runSummaries[realRunID]?.startedAt == stagingStartedAt)
        #expect(conversation.runSummaries[realRunID]?.finishedAt == stagingStartedAt)
    }

    private func waitForTerminal(_ conversation: ConversationModel) async {
        // Multi-turn scripted runs also exercise the bounded presentation
        // drain, so their terminal event can legitimately arrive after the
        // old one-second polling window.
        for _ in 0..<1_000 where !conversation.runState.isTerminal {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func wait(for condition: () async -> Bool) async {
        for _ in 0..<400 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Observable
@MainActor
private final class ComposerScrollerTestState {
    var text = ""
}

private struct ComposerScrollerTestView: View {
    @Bindable var state: ComposerScrollerTestState

    var body: some View {
        TextEditor(text: $state.text)
            .background { TextEditorScrollViewConfigurator() }
    }
}

@MainActor
private func requireComposerScroller(
    in root: NSView,
    condition: (NSScrollView) -> Bool = { _ in true }
) async throws -> NSScrollView {
    for _ in 0..<100 {
        root.layoutSubtreeIfNeeded()
        if let scrollView = composerScrollViews(in: root).first(where: condition),
            scrollView.autohidesScrollers
        {
            return scrollView
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The configured composer scroll view did not reach the expected state")
    throw ComposerScrollerTestError.expectedStateNotReached
}

private func composerScrollViews(in root: NSView) -> [NSScrollView] {
    var result: [NSScrollView] = []
    func visit(_ view: NSView) {
        if let scrollView = view as? NSScrollView,
            let textView = scrollView.documentView as? NSTextView,
            textView.isEditable
        {
            result.append(scrollView)
        }
        view.subviews.forEach(visit)
    }
    visit(root)
    return result
}

private enum ComposerScrollerTestError: Error {
    case expectedStateNotReached
}

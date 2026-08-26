import Foundation
import Testing

@testable import Termind

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
    func markStarted() { started = true }
    func markCancelled() { cancelled = true }
}

@Suite
@MainActor
struct ChatComposerStateTests {
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
    func reasoningEffortExposesTheFullScaleAndDefaultsToMedium() {
        #expect(
            ReasoningEffort.allCases
                == [.off, .minimal, .low, .medium, .high, .xHigh, .max]
        )
        #expect(ConversationModel().reasoningEffort == .medium)
        #expect(ReasoningEffort.xHigh.displayName == "Extra High")
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
    func permissionModesHaveTheExpectedOrderAndSafeInitialDefault() {
        #expect(
            ChatPermissionMode.allCases
                == [.askForApproval, .approveForMe, .fullAccess]
        )

        let store = AIConfigurationModel(persistsSecrets: false)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .askForApproval)
    }

    @Test
    func latestPermissionFeedsUnsetConversationsWhileExplicitChoiceWins() {
        let store = AIConfigurationModel(persistsSecrets: false)
        let unset = ConversationModel()
        let explicit = ConversationModel()
        explicit.permissionMode = .askForApproval

        store.select(ChatPermissionMode.approveForMe)

        #expect(store.resolve(conversation: unset.permissionMode) == .approveForMe)
        #expect(store.resolve(conversation: explicit.permissionMode) == .askForApproval)

        store.select(ChatPermissionMode.fullAccess)

        #expect(store.resolve(conversation: unset.permissionMode) == .fullAccess)
        #expect(store.resolve(conversation: explicit.permissionMode) == .askForApproval)
    }

    @Test
    func permissionDefaultCanBeSeededForAnAppSession() {
        let store = AIConfigurationModel(
            lastSelectedPermissionMode: .approveForMe,
            persistsSecrets: false
        )

        #expect(store.lastSelectedPermissionMode == .approveForMe)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .approveForMe)
    }

    @Test
    func permissionDefaultPersistsAcrossStoreInstancesIncludingFullAccess() throws {
        let suiteName = "ChatPermissionMode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = AIConfigurationModel(persistsSecrets: false, permissionDefaults: defaults)
        first.select(ChatPermissionMode.approveForMe)

        let second = AIConfigurationModel(persistsSecrets: false, permissionDefaults: defaults)
        #expect(second.lastSelectedPermissionMode == .approveForMe)

        second.select(ChatPermissionMode.fullAccess)

        let third = AIConfigurationModel(persistsSecrets: false, permissionDefaults: defaults)
        #expect(third.lastSelectedPermissionMode == .fullAccess)

        let explicit = ConversationModel()
        explicit.permissionMode = .askForApproval
        #expect(third.resolve(conversation: explicit.permissionMode) == .askForApproval)
    }

    @Test
    func missingPersistedPermissionDefaultsToAskForApproval() throws {
        let suiteName = "ChatPermissionMode-Missing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AIConfigurationModel(persistsSecrets: false, permissionDefaults: defaults)

        #expect(store.lastSelectedPermissionMode == .askForApproval)
    }

    @Test
    func invalidPersistedPermissionDefaultsToAskForApproval() throws {
        let suiteName = "ChatPermissionMode-Invalid-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("unknown-mode", forKey: SettingsKey.agentPermissionMode)

        let store = AIConfigurationModel(persistsSecrets: false, permissionDefaults: defaults)

        #expect(store.lastSelectedPermissionMode == .askForApproval)
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
    func immediatelyCompletedRuntimeStillReachesTheConversation() async {
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: ImmediateConversationAgentModel(turns: [
                [
                    .textDelta("partial"), .textSnapshot("visible immediately"),
                    .finished(.completed),
                ]
            ]),
            tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "hello",
                permissionMode: .askForApproval
            ))
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
                target: .local, safety: .locallyReadOnly
            )
        ) { invocation, _ in
            #expect(invocation.call.arguments == .object(["query": .string("hosts")]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "host-a")
        }
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        conversation.start(
            runtime: runtime,
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            ))
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
                target: .local, safety: .locallyReadOnly
            )
        ) { invocation, _ in
            AgentToolResult(callID: invocation.call.id, content: "host-a")
        }
        let conversation = ConversationModel()
        conversation.appendUserTurn("inspect")
        // The prompt travels on the request, so it must not also be replayed.
        #expect(conversation.pendingPriorMessages.isEmpty)

        conversation.start(
            runtime: AgentRuntime(
                model: model, tools: [tool],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            )
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
    func stopCancelsTheRunAndNotOnlyItsEventStream() async {
        let probe = ConversationCancellationProbe()
        let tool = AnyAgentTool(
            descriptor: AgentToolDescriptor(
                name: "wait", summary: "wait",
                inputSchema: .object([
                    "type": .string("object"), "properties": .object([:]),
                    "required": .array([]), "additionalProperties": .bool(false),
                ]),
                target: .local, safety: .locallyReadOnly
            )
        ) { invocation, _ in
            await probe.markStarted()
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                await probe.markCancelled()
                throw error
            }
            return AgentToolResult(callID: invocation.call.id, content: "never")
        }
        let conversation = ConversationModel()
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
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "wait for me",
                permissionMode: .askForApproval
            )
        )
        await wait { await probe.started }
        #expect(await probe.started)

        conversation.stop()

        await wait { await probe.cancelled }
        #expect(await probe.cancelled)
        #expect(conversation.runState == .cancelled)
        #expect(!conversation.isStreaming)
    }

    /// Messages and tool cards were two lists drawn one after the other, so a
    /// run that alternated between talking and acting read back as all the text
    /// followed by all the cards.
    @Test
    func timelineInterleavesToolCardsWithTheMessagesTheyBelongTo() async {
        let conversation = ConversationModel()
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
                            target: .local, safety: .locallyReadOnly
                        )
                    ) { invocation, _ in
                        AgentToolResult(callID: invocation.call.id, content: "host-a")
                    }
                ],
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "inspect",
                permissionMode: .askForApproval
            )
        )
        await waitForTerminal(conversation)

        let kinds = conversation.timeline.map { item in
            switch item {
            case .message(let message): message.role == .user ? "user" : "assistant"
            case .tool: "tool"
            case .plan: "plan"
            case .compaction: "compaction"
            case .compactionActivity: "compaction-activity"
            }
        }
        #expect(kinds == ["user", "assistant", "tool", "assistant"])
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
                    userInteraction: WeakAgentUserInteraction(conversation)
                ),
                request: AgentRunRequest(
                    conversationID: conversation.id, prompt: "hello",
                    permissionMode: .askForApproval
                )
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
        // The run must be started with this text, so the visible turn, the
        // model-facing transcript, and the request all say the same thing.
        #expect(conversation.messages.last?.text == sent)
        #expect(conversation.transcript.last?.text == sent)
    }

    /// Consumed, not kept: the payload is in the transcript from here on, and
    /// re-uploading it every turn is the bill the user's own key pays.
    @Test
    func anAttachmentIsConsumedByTheTurnAndNotResent() {
        let conversation = ConversationModel()
        conversation.attach(ContextChip(kind: .file, label: "nginx.conf", content: "worker;"))

        conversation.appendUserTurn("first")
        #expect(conversation.attachments.isEmpty)

        let second = conversation.appendUserTurn("second")
        #expect(second == "second")
    }

    @Test
    func detachingRemovesTheChipAndItsPayload() {
        let conversation = ConversationModel()
        let chip = ContextChip(kind: .selection, label: "Selection", content: "df -h")
        conversation.attach(chip)
        conversation.attach(chip)

        #expect(conversation.attachments.count == 1, "the same attachment twice is once")

        conversation.detach(chip.id)

        #expect(conversation.attachments.isEmpty)
        #expect(conversation.appendUserTurn("hello") == "hello")
    }

    // MARK: - Titling

    @Test
    func aFinishedRunNotifiesItsOwnerExactlyOnce() async {
        let conversation = ConversationModel()
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
                approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
            ),
            request: AgentRunRequest(
                conversationID: conversation.id, prompt: "hello",
                permissionMode: .askForApproval
            )
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

    /// A run that failed writes its reason to the visible list only. Titling off
    /// `messages` would have named the conversation after the error.
    @Test
    func aFailureNoticeIsNotAnAnswerWorthNaming() {
        let conversation = ConversationModel()
        conversation.appendUserTurn("Root is at 99%")

        conversation.handle(.failed("The Chat model has no available credential."))

        #expect(conversation.messages.contains { $0.role == .assistant })
        #expect(AppModel.titleContext(for: conversation) == nil)
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

    @Test
    func derivedTitleFallsBackToTheOpeningLineUntilASummaryArrives() {
        let conversation = ConversationModel()
        #expect(conversation.derivedTitle == "New Chat")

        conversation.appendUserTurn("Root is at 99%\nand climbing")
        #expect(conversation.derivedTitle == "Root is at 99%")

        conversation.title = "Disk pressure on root"
        #expect(conversation.derivedTitle == "Disk pressure on root")
    }

    private func waitForTerminal(_ conversation: ConversationModel) async {
        for _ in 0..<200 where !conversation.runState.isTerminal {
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

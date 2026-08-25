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
    func next() -> Int { defer { value += 1 }; return value }
}

private actor ConversationExecutionCounter {
    var value = 0
    func increment() { value += 1 }
}

@Suite
@MainActor
struct ChatComposerStateTests {
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

        let store = AIStore(persistsSecrets: false)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .askForApproval)
    }

    @Test
    func latestPermissionFeedsUnsetConversationsWhileExplicitChoiceWins() {
        let store = AIStore(persistsSecrets: false)
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
        let store = AIStore(
            lastSelectedPermissionMode: .approveForMe,
            persistsSecrets: false
        )

        #expect(store.lastSelectedPermissionMode == .approveForMe)
        #expect(store.resolve(conversation: nil as ChatPermissionMode?) == .approveForMe)
    }

    @Test
    func modelSelectionStillFeedsUnsetConversationsWithoutOverridingExplicitOnes() {
        let firstModel = AIModel(id: "first")
        let secondModel = AIModel(id: "second")
        let provider = ModelProvider(
            name: "Test Provider",
            models: [firstModel, secondModel]
        )
        let store = AIStore(modelProviders: [provider], persistsSecrets: false)
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
        conversation.handle(.messageFinished(AgentTranscriptMessage(
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
            model: ImmediateConversationAgentModel(turns: [[
                .textDelta("partial"), .textSnapshot("visible immediately"),
                .finished(.completed),
            ]]),
            tools: [],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        conversation.start(runtime: runtime, request: AgentRunRequest(
            conversationID: conversation.id, prompt: "hello",
            permissionMode: .askForApproval
        ))
        await waitForTerminal(conversation)

        #expect(conversation.runState == .completed)
        #expect(conversation.messages.contains {
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
        let tool = AnyAgentTool(descriptor: AgentToolDescriptor(
            name: "lookup", summary: "lookup",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "query": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]),
            target: .local, safety: .locallyReadOnly
        )) { invocation, _ in
            #expect(invocation.call.arguments == .object(["query": .string("hosts")]))
            await executions.increment()
            return AgentToolResult(callID: invocation.call.id, content: "host-a")
        }
        let conversation = ConversationModel()
        let runtime = AgentRuntime(
            model: model, tools: [tool],
            approval: AgentApprovalBroker(reviewer: nil, manualApproval: { _ in .allow })
        )

        conversation.start(runtime: runtime, request: AgentRunRequest(
            conversationID: conversation.id, prompt: "inspect",
            permissionMode: .askForApproval
        ))
        await waitForTerminal(conversation)

        #expect(await executions.value == 1)
        #expect(conversation.runState == .completed)
        #expect(conversation.messages.contains {
            $0.role == .assistant && $0.text == "tool result is visible"
        })
    }

    private func waitForTerminal(_ conversation: ConversationModel) async {
        for _ in 0..<200 where !conversation.runState.isTerminal {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

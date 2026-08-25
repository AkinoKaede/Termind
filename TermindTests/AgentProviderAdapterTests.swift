import Foundation
import Testing

@testable import Termind

@Suite
struct AgentProviderAdapterTests {
    @Test
    func commandComposerRequestUsesBufferedJSONInsteadOfSSE() throws {
        var provider = ModelProvider(name: "OpenAI")
        provider.usesResponsesAPI = true
        let client = AgentProviderClient(
            provider: provider, model: AIModel(id: "gpt-test"), secret: "test"
        )
        let modelRequest = AgentModelRequest(
            systemPrompt: "Compose", messages: [], tools: []
        )

        let request = try client.buildRequest(modelRequest, streaming: false)
        let bodyData = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )

        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(body["stream"] as? Bool == false)
        #expect(body["tools"] == nil)
    }

    @Test
    func securityReviewPrefersLowReasoningThenClampsUpward() {
        let provider = ModelProvider(name: "Gateway")
        var lowModel = AIModel(id: "low-reviewer")
        lowModel.abilities.insert(.reasoning)
        lowModel.reasoningProfile = ReasoningProfile(levels: [
            .low: ReasoningLevelMapping(isSupported: true),
            .high: ReasoningLevelMapping(isSupported: true),
        ])
        var highOnlyModel = AIModel(id: "high-reviewer")
        highOnlyModel.abilities.insert(.reasoning)
        highOnlyModel.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true),
            .max: ReasoningLevelMapping(isSupported: true),
        ])

        #expect(
            SecurityReviewClient.preferredReasoning(model: lowModel, provider: provider)
                == .low
        )
        #expect(
            SecurityReviewClient.preferredReasoning(model: highOnlyModel, provider: provider)
                == .high
        )

        var responsesProvider = provider
        responsesProvider.usesResponsesAPI = true
        let request = AgentModelRequest(systemPrompt: "Review", messages: [], tools: [])
        let lowBody = AgentProviderClient(
            provider: responsesProvider, model: lowModel, secret: "test", reasoning: .low
        ).body(request)
        let highBody = AgentProviderClient(
            provider: responsesProvider, model: highOnlyModel, secret: "test", reasoning: .low
        ).body(request)

        #expect((lowBody["reasoning"] as? [String: String])?["effort"] == "low")
        #expect((highBody["reasoning"] as? [String: String])?["effort"] == "high")
    }

    @Test
    func openAIStrictSchemaRequiresEveryPropertyAndMakesOptionalsNullable() throws {
        let normalized = AgentProviderClient.openAIStrictSchema(.object([
            "type": .string("object"),
            "properties": .object([
                "url": .object(["type": .string("string")]),
                "method": .object([
                    "type": .string("string"),
                    "enum": .array([.string("GET"), .string("HEAD")]),
                ]),
            ]),
            "required": .array([.string("url")]),
            "additionalProperties": .bool(false),
        ]))
        let object = try #require(normalized.objectValue)
        #expect(Set(object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == ["url", "method"])
        let method = try #require(object["properties"]?.objectValue?["method"]?.objectValue)
        #expect(method["type"] == .array([.string("string"), .string("null")]))
        #expect(object["additionalProperties"] == .bool(false))
    }

    @Test
    func openAIResponsesParsesTextAndPartialArguments() {
        #expect(AgentProviderClient.parseResponses(
            "response.output_text.delta", ["delta": "hello"]
        ).firstText == "hello")
        let tool = AgentProviderClient.parseResponses(
            "response.function_call_arguments.delta",
            ["call_id": "call-1", "name": "ssh_exec", "delta": "{\"host_id\":" ]
        )
        #expect(tool.firstTool?.id == "call-1")
        #expect(tool.firstTool?.arguments == "{\"host_id\":")
    }

    @Test
    func responsesUsesJSONTypeWhenSSEEventNameIsMissing() {
        let type = AgentProviderClient.streamEventType(
            SSEEvent(data: #"{"type":"response.output_item.added"}"#),
            root: ["type": "response.output_item.added"]
        )

        #expect(type == "response.output_item.added")
    }

    @Test
    func openAIResponsesParsesCompatibleCompletedResponseWithEmptyArguments() {
        let response: [String: Any] = [
            "object": "response", "status": "completed",
            "output": [
                [
                    "type": "message",
                    "content": [["type": "output_text", "text": "Checking hosts."]],
                ],
                [
                    "type": "function_call", "id": "item-1", "call_id": "call-1",
                    "name": "list_hosts", "arguments": "",
                ],
            ],
        ]
        let events = AgentProviderClient.parseCompletedResponses(response)

        #expect(events.firstText == "Checking hosts.")
        #expect(events.firstTool?.id == "call-1")
        #expect(events.firstTool?.name == "list_hosts")
        #expect(events.firstTool?.arguments == "")
        #expect(events.containsFinish == .toolCalls)

        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        let completedEvent = AgentProviderClient.parseResponses(
            "response.completed", response,
            callIDs: &ids, callNames: &names
        )
        #expect(completedEvent.firstText == "Checking hosts.")
        #expect(completedEvent.firstTool?.name == "list_hosts")
        #expect(completedEvent.containsFinish == .toolCalls)
    }

    @Test
    func openAIResponsesParsesCommandComposerJSONSnapshot() {
        let response: [String: Any] = [
            "object": "response", "status": "completed",
            "output": [[
                "type": "message", "status": "completed",
                "content": [[
                    "type": "output_text", "text": #"{"command":"ls"}"#,
                ]],
            ]],
        ]

        let events = AgentProviderClient.parseCompletedResponses(response)

        guard case .textSnapshot(let text) = events.first else {
            Issue.record("Expected a command JSON text snapshot")
            return
        }
        #expect(text == #"{"command":"ls"}"#)
        #expect(events.containsFinish == .completed)
    }

    @Test
    func openAIResponsesMapsItemIDArgumentDeltasBackToCallID() {
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        let added = AgentProviderClient.parseResponses(
            "response.output_item.added",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "list_hosts", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names
        )
        let delta = AgentProviderClient.parseResponses(
            "response.function_call_arguments.delta",
            ["item_id": "item-1", "delta": "{}"],
            callIDs: &ids, callNames: &names
        )

        #expect(added.firstTool?.id == "call-1")
        #expect(delta.firstTool?.id == "call-1")
        #expect(delta.firstTool?.name == "list_hosts")
        #expect(delta.firstTool?.arguments == "{}")
    }

    @Test
    func openAIResponsesAcceptsDoneOnlyFunctionCalls() {
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        let events = AgentProviderClient.parseResponses(
            "response.output_item.done",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "list_hosts", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names
        )

        #expect(events.firstTool?.id == "call-1")
        #expect(events.firstTool?.name == "list_hosts")
        #expect(events.firstTool?.arguments == "")
    }

    @Test
    func openAIResponsesUsesDoneSnapshotWhenAddedHadNoArguments() {
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        let added = AgentProviderClient.parseResponses(
            "response.output_item.added",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "fetch", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names
        )
        let done = AgentProviderClient.parseResponses(
            "response.output_item.done",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "fetch", "arguments": #"{"url":"https://example.com"}"#,
            ]],
            callIDs: &ids, callNames: &names
        )

        #expect(added.firstTool?.arguments == "")
        #expect(done.firstTool?.id == "call-1")
        #expect(done.firstTool?.name == "fetch")
        #expect(done.firstTool?.arguments == #"{"url":"https://example.com"}"#)
    }

    @Test
    func openAIResponsesUsesCompletedResponseAsFinalToolSnapshot() {
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        _ = AgentProviderClient.parseResponses(
            "response.output_item.added",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "fetch", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names
        )
        let completed = AgentProviderClient.parseResponses(
            "response.completed",
            ["response": [
                "object": "response", "status": "completed",
                "output": [[
                    "type": "function_call", "id": "item-1", "call_id": "call-1",
                    "name": "fetch", "arguments": #"{"url":"https://example.com"}"#,
                ]],
            ]],
            callIDs: &ids, callNames: &names
        )

        #expect(completed.firstTool?.id == "call-1")
        #expect(completed.firstTool?.arguments == #"{"url":"https://example.com"}"#)
        #expect(completed.containsFinish == .toolCalls)
    }

    @Test
    func openAIResponsesPreservesReasoningAndNativeFunctionItemForTheNextTurn() throws {
        let reasoning: [String: Any] = [
            "type": "reasoning", "id": "reasoning-1",
            "encrypted_content": "opaque-provider-state",
            "summary": [],
        ]
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        let reasoningEvents = AgentProviderClient.parseResponses(
            "response.output_item.done", ["item": reasoning],
            callIDs: &ids, callNames: &names
        )
        let providerItem = try #require(reasoningEvents.firstProviderItem)

        var provider = ModelProvider(name: "Responses")
        provider.usesResponsesAPI = true
        let assistant = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [AgentToolCall(
                id: "call-1", name: "lookup",
                arguments: .object(["query": .string("hosts")]),
                providerItemID: "item-1"
            )],
            providerItems: [providerItem]
        )
        let result = AgentTranscriptMessage(
            role: .tool, text: "host-a", toolCallID: "call-1", toolName: "lookup"
        )
        let body = AgentProviderClient(
            provider: provider, model: AIModel(id: "gpt-test"), secret: "test"
        ).body(AgentModelRequest(
            systemPrompt: "test", messages: [assistant, result], tools: []
        ))
        let input = try #require(body["input"] as? [[String: Any]])

        let replayedReasoning = try #require(input.first { $0["type"] as? String == "reasoning" })
        #expect(replayedReasoning["id"] as? String == "reasoning-1")
        #expect(replayedReasoning["encrypted_content"] as? String == "opaque-provider-state")

        let functionCall = try #require(input.first { $0["type"] as? String == "function_call" })
        #expect(functionCall["id"] as? String == "item-1")
        #expect(functionCall["call_id"] as? String == "call-1")
        #expect(functionCall["name"] as? String == "lookup")

        let functionResult = try #require(input.first {
            $0["type"] as? String == "function_call_output"
        })
        #expect(functionResult["call_id"] as? String == "call-1")
        #expect(functionResult["output"] as? String == "host-a")
    }

    @Test
    func openAIChatRetainsCallIDAcrossChunks() {
        var ids: [Int: String] = [:]
        _ = AgentProviderClient.parseChat([
            "choices": [["delta": ["tool_calls": [[
                "index": 0, "id": "call-1",
                "function": ["name": "fetch", "arguments": "{\"url\":"]
            ]]]]]
        ], callIDs: &ids)
        let next = AgentProviderClient.parseChat([
            "choices": [["delta": ["tool_calls": [[
                "index": 0, "function": ["arguments": "\"https://example.com\"}"]
            ]]], "finish_reason": "tool_calls"]]
        ], callIDs: &ids)
        #expect(next.firstTool?.id == "call-1")
        #expect(next.containsFinish == .toolCalls)
    }

    @Test
    func anthropicRetainsNativeToolUseIDAcrossPartialJSON() {
        var ids: [Int: String] = [:]
        let start = AgentProviderClient.parseAnthropic(
            "content_block_start",
            ["index": 1, "content_block": [
                "type": "tool_use", "id": "toolu_123", "name": "sftp_read",
            ]],
            callIDs: &ids
        )
        let delta = AgentProviderClient.parseAnthropic(
            "content_block_delta",
            ["index": 1, "delta": ["partial_json": "{\"path\":\"/tmp\"}"]],
            callIDs: &ids
        )
        #expect(start.firstTool?.id == "toolu_123")
        #expect(delta.firstTool?.id == "toolu_123")
    }

    @Test
    func geminiParsesFunctionCallAndFinish() {
        let events = AgentProviderClient.parseGoogle([
            "candidates": [[
                "content": ["parts": [[
                    "functionCall": ["name": "list_hosts", "args": [:]],
                ]]],
                "finishReason": "STOP",
            ]]
        ])
        #expect(events.firstTool?.name == "list_hosts")
        #expect(events.containsFinish == .toolCalls)
    }
}

private extension [AgentModelStreamEvent] {
    var firstText: String? {
        for event in self {
            switch event {
            case .textDelta(let text), .textSnapshot(let text): return text
            default: continue
            }
        }
        return nil
    }

    var firstTool: (id: String, name: String?, arguments: String)? {
        for event in self {
            switch event {
            case .toolCallDelta(let id, let name, let arguments):
                return (id, name, arguments)
            case .toolCallSnapshot(let id, _, let name, let arguments):
                return (id, name, arguments)
            default: continue
            }
        }
        return nil
    }

    var containsFinish: AgentStopReason? {
        for case .finished(let reason) in self { return reason }
        return nil
    }

    var firstProviderItem: AgentJSONValue? {
        for case .providerItem(let item) in self { return item }
        return nil
    }
}

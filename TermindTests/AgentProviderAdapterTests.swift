import Foundation
import Testing

@testable import Termind

@Suite
struct AgentProviderAdapterTests {
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
        var sawOutput = false
        let completedEvent = AgentProviderClient.parseResponses(
            "response.completed", response,
            callIDs: &ids, callNames: &names, sawOutput: &sawOutput
        )
        #expect(completedEvent.firstText == "Checking hosts.")
        #expect(completedEvent.firstTool?.name == "list_hosts")
        #expect(completedEvent.containsFinish == .toolCalls)
    }

    @Test
    func openAIResponsesMapsItemIDArgumentDeltasBackToCallID() {
        var ids: [String: String] = [:]
        var names: [String: String] = [:]
        var sawOutput = false
        let added = AgentProviderClient.parseResponses(
            "response.output_item.added",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "list_hosts", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names, sawOutput: &sawOutput
        )
        let delta = AgentProviderClient.parseResponses(
            "response.function_call_arguments.delta",
            ["item_id": "item-1", "delta": "{}"],
            callIDs: &ids, callNames: &names, sawOutput: &sawOutput
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
        var sawOutput = false
        let events = AgentProviderClient.parseResponses(
            "response.output_item.done",
            ["item": [
                "type": "function_call", "id": "item-1", "call_id": "call-1",
                "name": "list_hosts", "arguments": "",
            ]],
            callIDs: &ids, callNames: &names, sawOutput: &sawOutput
        )

        #expect(events.firstTool?.id == "call-1")
        #expect(events.firstTool?.name == "list_hosts")
        #expect(events.firstTool?.arguments == "")
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
        for case .textDelta(let text) in self { return text }
        return nil
    }

    var firstTool: (id: String, name: String?, arguments: String)? {
        for case .toolCallDelta(let id, let name, let arguments) in self {
            return (id, name, arguments)
        }
        return nil
    }

    var containsFinish: AgentStopReason? {
        for case .finished(let reason) in self { return reason }
        return nil
    }
}

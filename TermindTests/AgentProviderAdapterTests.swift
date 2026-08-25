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
        var state = AnthropicStreamState()
        let start = AgentProviderClient.parseAnthropic(
            "content_block_start",
            ["index": 1, "content_block": [
                "type": "tool_use", "id": "toolu_123", "name": "sftp_read",
            ]],
            state: &state
        )
        let delta = AgentProviderClient.parseAnthropic(
            "content_block_delta",
            ["index": 1, "delta": ["partial_json": "{\"path\":\"/tmp\"}"]],
            state: &state
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

    // MARK: - Provider-native web search

    @Test
    func nativeSearchToolIsSentOnlyWhenAsked() throws {
        var anthropic = ModelProvider(name: "Anthropic")
        anthropic.kind = .anthropic

        let off = Self.body(anthropic, webSearch: false, tools: [Self.lookupTool])
        let offTools = try #require(off["tools"] as? [[String: Any]])
        #expect(offTools.count == 1)
        #expect(!offTools.contains { $0["type"] as? String == "web_search_20250305" })

        let on = Self.body(anthropic, webSearch: true, tools: [Self.lookupTool])
        let onTools = try #require(on["tools"] as? [[String: Any]])
        #expect(onTools.count == 2)
        let server = try #require(onTools.first { $0["type"] as? String == "web_search_20250305" })
        #expect(server["name"] as? String == "web_search")
        #expect(server["max_uses"] as? Int == AgentProviderClient.nativeWebSearchMaxUses)
    }

    /// The guard that used to be skipped: `tools` was only set when the local
    /// list was non-empty, so a chat with no tools got no search either.
    @Test
    func nativeSearchSurvivesAnEmptyLocalToolList() throws {
        var anthropic = ModelProvider(name: "Anthropic")
        anthropic.kind = .anthropic
        let anthropicTools = try #require(
            Self.body(anthropic, webSearch: true, tools: [])["tools"] as? [[String: Any]]
        )
        #expect(anthropicTools.count == 1)
        #expect(anthropicTools[0]["type"] as? String == "web_search_20250305")

        var responses = ModelProvider(name: "Responses")
        responses.usesResponsesAPI = true
        let responseTools = try #require(
            Self.body(responses, webSearch: true, tools: [])["tools"] as? [[String: Any]]
        )
        #expect(responseTools.count == 1)
        #expect(responseTools[0]["type"] as? String == "web_search")
    }

    /// Chat Completions is also every OpenAI-compatible gateway Termind talks
    /// to, and an unknown tool type there is a 400 on every message.
    @Test
    func chatCompletionsNeverAsksForNativeSearch() throws {
        let provider = ModelProvider(name: "Gateway")
        var capable = AIModel(id: "gpt-5.4")
        capable.abilities = [.toolCall, .webSearch]
        #expect(!provider.supportsNativeWebSearch(model: capable))

        let body = Self.body(provider, webSearch: true, tools: [Self.lookupTool])
        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "function")
        #expect(body["web_search_options"] == nil)
    }

    @Test
    func googleSendsSearchAsItsOwnToolGroup() throws {
        var provider = ModelProvider(name: "Google")
        provider.kind = .google

        let tools = try #require(
            Self.body(provider, webSearch: true, tools: [Self.lookupTool])["tools"]
                as? [[String: Any]]
        )
        // Two entries, not two keys in one entry — the arrangement Gemini
        // rejects is `functionDeclarations` and `google_search` as siblings
        // inside a single object.
        #expect(tools.count == 2)
        #expect(tools.contains { $0["functionDeclarations"] != nil })
        #expect(tools.contains { $0["google_search"] != nil })
        #expect(tools.allSatisfy { $0.count == 1 })
    }

    /// The regression that costs a whole turn.
    ///
    /// `server_tool_use` streams `input_json_delta` exactly like `tool_use`
    /// does. Read as a tool call it produces one with an empty name, which
    /// `AgentRuntime` rejects with `invalidToolCall` — so a single native
    /// search would fail the entire assistant turn.
    @Test
    func anthropicServerToolBlocksNeverBecomeToolCalls() {
        var state = AnthropicStreamState()
        var events: [AgentModelStreamEvent] = []

        events += AgentProviderClient.parseAnthropic(
            "content_block_start",
            [
                "index": 0,
                "content_block": [
                    "type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
                ],
            ],
            state: &state
        )
        for chunk in [#"{"query""#, #": "swift 6""#, "}"] {
            events += AgentProviderClient.parseAnthropic(
                "content_block_delta",
                ["index": 0, "delta": ["type": "input_json_delta", "partial_json": chunk]],
                state: &state
            )
        }
        events += AgentProviderClient.parseAnthropic(
            "content_block_stop", ["index": 0], state: &state
        )

        #expect(events.firstTool == nil)
        #expect(events.isEmpty)
    }

    @Test
    func anthropicPairsItsSearchQueryWithItsResults() throws {
        var state = AnthropicStreamState()
        var events: [AgentModelStreamEvent] = []

        events += AgentProviderClient.parseAnthropic(
            "content_block_start",
            [
                "index": 0,
                "content_block": [
                    "type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search",
                ],
            ],
            state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_delta",
            [
                "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": #"{"query": "swift 6"}"#],
            ],
            state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_stop", ["index": 0], state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_start",
            [
                "index": 1,
                "content_block": [
                    "type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
                    "content": [
                        ["type": "web_search_result", "url": "https://swift.org", "title": "Swift"]
                    ],
                ],
            ],
            state: &state
        )
        // The model's own text still streams normally afterwards.
        events += AgentProviderClient.parseAnthropic(
            "content_block_delta",
            ["index": 2, "delta": ["type": "text_delta", "text": "Swift 6 ships"]],
            state: &state
        )

        let activity = try #require(events.firstWebSearch)
        #expect(activity.query == "swift 6")
        #expect(activity.sources.map(\.url) == ["https://swift.org"])
        #expect(events.firstText == "Swift 6 ships")
        #expect(events.firstTool == nil)
    }

    /// A failed search replaces the array of hits with a single error object.
    @Test
    func anthropicSearchErrorYieldsNoSources() throws {
        var state = AnthropicStreamState()
        let events = AgentProviderClient.parseAnthropic(
            "content_block_start",
            [
                "index": 0,
                "content_block": [
                    "type": "web_search_tool_result", "tool_use_id": "srvtoolu_1",
                    "content": ["type": "web_search_tool_result_error", "error_code": "max_uses_exceeded"],
                ],
            ],
            state: &state
        )
        let activity = try #require(events.firstWebSearch)
        #expect(activity.sources.isEmpty)
    }

    /// Two events for one item: the verbatim call has to go back to OpenAI next
    /// turn, and the card wants the query, which the API would not understand.
    @Test
    func responsesSearchCallIsBothReplayedAndShown() throws {
        let events = AgentProviderClient.parseResponses(
            "response.output_item.done",
            [
                "item": [
                    "type": "web_search_call", "id": "ws_1", "status": "completed",
                    "action": ["type": "search", "query": "swift 6 release date"],
                ]
            ]
        )

        let activity = try #require(events.firstWebSearch)
        #expect(activity.query == "swift 6 release date")
        // Sources are absent on purpose: Responses reports them as
        // `url_citation` annotations on the message, not on this item.
        #expect(activity.sources.isEmpty)

        let item = try #require(events.firstProviderItem)
        #expect(item.objectValue?["type"]?.stringValue == "web_search_call")
        #expect(item.objectValue?["id"]?.stringValue == "ws_1")
        #expect(events.firstTool == nil)
    }

    @Test
    func responsesSearchCallReplaysInTheNextRequest() throws {
        let item = try #require(
            AgentProviderClient.parseResponses(
                "response.output_item.done",
                [
                    "item": [
                        "type": "web_search_call", "id": "ws_1", "status": "completed",
                        "action": ["type": "search", "query": "swift 6"],
                    ]
                ]
            ).firstProviderItem
        )
        var provider = ModelProvider(name: "Responses")
        provider.usesResponsesAPI = true
        let body = AgentProviderClient(
            provider: provider, model: AIModel(id: "gpt-test"), secret: "test"
        ).body(AgentModelRequest(
            systemPrompt: "test",
            messages: [AgentTranscriptMessage(role: .assistant, providerItems: [item])],
            tools: []
        ))

        let input = try #require(body["input"] as? [[String: Any]])
        #expect(input.contains { $0["type"] as? String == "web_search_call" })
    }

    @Test
    func googleGroundingMetadataBecomesOneSearchCard() throws {
        let events = AgentProviderClient.parseGoogle([
            "candidates": [[
                "content": ["parts": [["text": "Swift 6 shipped."]]],
                "groundingMetadata": [
                    "webSearchQueries": ["swift 6 release"],
                    "groundingChunks": [
                        ["web": ["uri": "https://swift.org/blog", "title": "swift.org"]],
                        ["web": ["title": "no uri"]],
                    ],
                ],
                "finishReason": "STOP",
            ]]
        ])

        let activity = try #require(events.firstWebSearch)
        #expect(activity.query == "swift 6 release")
        #expect(activity.sources.map(\.url) == ["https://swift.org/blog"])
        #expect(events.firstText == "Swift 6 shipped.")
        #expect(events.containsFinish == .completed)
    }

    /// Gemini can report grounding on a chunk that carries no `content` at all.
    @Test
    func googleGroundingIsReadFromAContentlessChunk() throws {
        let events = AgentProviderClient.parseGoogle([
            "candidates": [[
                "groundingMetadata": ["webSearchQueries": ["swift 6"]],
            ]]
        ])
        #expect(events.firstWebSearch?.query == "swift 6")
    }

    // MARK: - Helpers

    private static let lookupTool = AgentToolDescriptor(
        name: "lookup", summary: "Look something up.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object(["query": .object(["type": .string("string")])]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false),
        ]),
        target: .local, safety: .locallyReadOnly
    )

    private static func body(
        _ provider: ModelProvider, webSearch: Bool, tools: [AgentToolDescriptor]
    ) -> [String: Any] {
        AgentProviderClient(
            provider: provider, model: AIModel(id: "model-test"), secret: "test",
            webSearch: webSearch
        ).body(AgentModelRequest(systemPrompt: "test", messages: [], tools: tools))
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

    var firstWebSearch: AgentWebSearchActivity? {
        for case .webSearch(let activity) in self { return activity }
        return nil
    }
}

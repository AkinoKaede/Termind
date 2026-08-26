import Foundation
import Testing

@testable import Termind

@Suite
struct AgentProviderAdapterTests {
    @Test
    func everyProviderEncodesUserImagesAsNativeMultimodalParts() throws {
        let image = AgentImageAttachment(
            label: "diagram.png", mimeType: "image/png", data: Data([1, 2, 3]),
            pixelWidth: 10, pixelHeight: 20
        )
        let message = AgentTranscriptMessage(role: .user, text: "Explain", images: [image])

        var responses = ModelProvider(name: "Responses")
        responses.usesResponsesAPI = true
        let responsesBody = Self.body(
            responses, webSearch: false, tools: [], messages: [message]
        )
        let input = try #require(responsesBody["input"] as? [[String: Any]])
        let responseContent = try #require(input.first?["content"] as? [[String: Any]])
        #expect(responseContent.contains { $0["type"] as? String == "input_image" })

        let chatBody = Self.body(
            ModelProvider(name: "Chat"), webSearch: false, tools: [], messages: [message]
        )
        let chatMessages = try #require(chatBody["messages"] as? [[String: Any]])
        let chatContent = try #require(chatMessages.last?["content"] as? [[String: Any]])
        #expect(chatContent.contains { $0["type"] as? String == "image_url" })

        let anthropicBody = Self.body(
            ModelProvider(name: "Anthropic", kind: .anthropic), webSearch: false,
            tools: [], messages: [message]
        )
        let anthropicMessages = try #require(
            anthropicBody["messages"] as? [[String: Any]]
        )
        let anthropicContent = try #require(
            anthropicMessages.first?["content"] as? [[String: Any]]
        )
        #expect(anthropicContent.contains { $0["type"] as? String == "image" })

        let googleBody = Self.body(
            ModelProvider(name: "Google", kind: .google), webSearch: false,
            tools: [], messages: [message]
        )
        let contents = try #require(googleBody["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        #expect(parts.contains { $0["inlineData"] != nil })
    }

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
    func responsesRequestsAutomaticReasoningSummary() throws {
        var provider = ModelProvider(name: "OpenAI")
        provider.usesResponsesAPI = true
        let body = AgentProviderClient(
            provider: provider, model: Self.reasoningModel(id: "gpt-reasoning"),
            secret: "test", reasoning: .high
        ).body(AgentModelRequest(systemPrompt: "test", messages: [], tools: []))

        let reasoning = try #require(body["reasoning"] as? [String: String])
        #expect(reasoning["effort"] == "high")
        #expect(reasoning["summary"] == "auto")
    }

    @Test
    func anthropicAdaptiveThinkingAndGoogleThoughtsAreRequested() throws {
        let anthropicBody = AgentProviderClient(
            provider: ModelProvider(name: "Anthropic", kind: .anthropic),
            model: Self.reasoningModel(id: "claude-sonnet-4-6"),
            secret: "test", reasoning: .high
        ).body(AgentModelRequest(systemPrompt: "test", messages: [], tools: []))
        let thinking = try #require(anthropicBody["thinking"] as? [String: String])
        #expect(thinking == ["type": "adaptive", "display": "summarized"])
        #expect((anthropicBody["output_config"] as? [String: String])?["effort"] == "high")
        #expect(thinking["budget_tokens"] == nil)

        let googleBody = AgentProviderClient(
            provider: ModelProvider(name: "Google", kind: .google),
            model: Self.reasoningModel(id: "gemini-reasoning"),
            secret: "test", reasoning: .high
        ).body(AgentModelRequest(systemPrompt: "test", messages: [], tools: []))
        let generation = try #require(googleBody["generationConfig"] as? [String: Any])
        let config = try #require(generation["thinkingConfig"] as? [String: Any])
        #expect(config["thinkingLevel"] as? String == "HIGH")
        #expect(config["includeThoughts"] as? Bool == true)
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
    func responsesUsesNativeNamespacesForDeclarationsReplayAndCalls() throws {
        var provider = ModelProvider(name: "OpenAI")
        provider.usesResponsesAPI = true
        let tool = Self.namespacedTool
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [
            AgentToolCall(
                id: "call-1", name: tool.qualifiedName,
                arguments: .object(["query": .string("swift")])
            )
        ])
        let body = AgentProviderClient(
            provider: provider, model: AIModel(id: "gpt-test"), secret: "test"
        ).body(AgentModelRequest(
            systemPrompt: "test", messages: [assistant], tools: [tool]
        ))

        let tools = try #require(body["tools"] as? [[String: Any]])
        let namespace = try #require(tools.first { $0["type"] as? String == "namespace" })
        #expect(namespace["name"] as? String == "a_b_c-d")
        let children = try #require(namespace["tools"] as? [[String: Any]])
        #expect(children.first?["type"] as? String == "function")
        #expect(children.first?["name"] as? String == "lookup")

        let input = try #require(body["input"] as? [[String: Any]])
        let replay = try #require(input.first { $0["type"] as? String == "function_call" })
        #expect(replay["namespace"] as? String == "a_b_c-d")
        #expect(replay["name"] as? String == "lookup")

        let parsed = AgentProviderClient.parseCompletedResponses([
            "object": "response", "status": "completed",
            "output": [[
                "type": "function_call", "call_id": "call-2",
                "namespace": "a_b_c-d", "name": "lookup", "arguments": "{}",
            ]],
        ])
        #expect(parsed.firstTool?.name == "a_b_c-d.lookup")
    }

    @Test
    func flatProvidersEncodeReplayAndDecodeCanonicalNames() throws {
        let tool = Self.namespacedTool
        let wire = "mcp__a_b_c-d__lookup"
        let assistant = AgentTranscriptMessage(role: .assistant, toolCalls: [
            AgentToolCall(id: "call-1", name: tool.qualifiedName, arguments: .object([:]))
        ])
        let result = AgentTranscriptMessage(
            role: .tool, text: "ok", toolCallID: "call-1", toolName: tool.qualifiedName
        )

        let openAIBody = Self.body(
            ModelProvider(name: "OpenAI"), webSearch: false, tools: [tool],
            messages: [assistant, result]
        )
        let openAITools = try #require(openAIBody["tools"] as? [[String: Any]])
        #expect((openAITools.first?["function"] as? [String: Any])?["name"] as? String == wire)
        let openAIMessages = try #require(openAIBody["messages"] as? [[String: Any]])
        let toolCallRows = openAIMessages.compactMap {
            $0["tool_calls"] as? [[String: Any]]
        }
        let openAICall = try #require(toolCallRows.first?.first)
        #expect((openAICall["function"] as? [String: Any])?["name"] as? String == wire)

        let anthropicBody = Self.body(
            ModelProvider(name: "Anthropic", kind: .anthropic), webSearch: false,
            tools: [tool], messages: [assistant, result]
        )
        #expect((anthropicBody["tools"] as? [[String: Any]])?.first?["name"] as? String == wire)
        let anthropicMessages = try #require(anthropicBody["messages"] as? [[String: Any]])
        let anthropicCall = try #require((anthropicMessages.first?["content"] as? [[String: Any]])?.first)
        #expect(anthropicCall["name"] as? String == wire)

        let googleBody = Self.body(
            ModelProvider(name: "Google", kind: .google), webSearch: false,
            tools: [tool], messages: [assistant, result]
        )
        let googleGroups = try #require(googleBody["tools"] as? [[String: Any]])
        let declarations = try #require(googleGroups.first?["functionDeclarations"] as? [[String: Any]])
        #expect(declarations.first?["name"] as? String == wire)
        let contents = try #require(googleBody["contents"] as? [[String: Any]])
        let functionResponse = try #require(
            ((contents.last?["parts"] as? [[String: Any]])?.first?["functionResponse"])
                as? [String: Any]
        )
        #expect(functionResponse["name"] as? String == wire)

        let names = AgentProviderToolNameMap.flat([tool]).wireToQualified
        #expect(AgentProviderClient.parseChat([
            "choices": [["message": ["tool_calls": [[
                "id": "call", "function": ["name": wire, "arguments": "{}"],
            ]]]]],
        ], wireNames: names).firstTool?.name == tool.qualifiedName)
        #expect(AgentProviderClient.parseCompletedAnthropic([
            "type": "message", "content": [[
                "type": "tool_use", "id": "call", "name": wire, "input": [:],
            ]],
        ], wireNames: names).firstTool?.name == tool.qualifiedName)
        #expect(AgentProviderClient.parseGoogle([
            "candidates": [["content": ["parts": [[
                "functionCall": ["name": wire, "args": [:]],
            ]]], "finishReason": "STOP"]],
        ], wireNames: names).firstTool?.name == tool.qualifiedName)
    }

    @Test
    func flatNameCollisionsNeverRenameBuiltInTools() {
        let builtIn = AgentToolDescriptor(
            name: "mcp__a_b_c-d__lookup", summary: "Built in",
            inputSchema: .object([:]), target: .local, safety: .locallyReadOnly
        )
        let names = AgentProviderToolNameMap.flat([Self.namespacedTool, builtIn])

        #expect(names.wireName(for: builtIn.qualifiedName) == builtIn.name)
        #expect(names.wireName(for: Self.namespacedTool.qualifiedName)
            == "mcp__a_b_c-d__lookup_2")
        #expect(names.qualifiedName(for: "mcp__a_b_c-d__lookup_2")
            == Self.namespacedTool.qualifiedName)
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
    func openAIResponsesKeepsReasoningSeparateFromAnswerText() {
        let delta = AgentProviderClient.parseResponses(
            "response.reasoning_summary_text.delta", ["delta": "Checked the constraints."]
        )
        #expect(delta.firstReasoning == "Checked the constraints.")
        #expect(delta.firstText == nil)

        let completed = AgentProviderClient.parseCompletedResponses([
            "object": "response", "status": "completed",
            "output": [
                [
                    "type": "reasoning", "id": "reasoning-1",
                    "summary": [[
                        "type": "summary_text", "text": "Compared both options.",
                    ]],
                ],
                [
                    "type": "message",
                    "content": [["type": "output_text", "text": "Use option B."]],
                ],
            ],
        ])
        #expect(completed.firstReasoning == "Compared both options.")
        #expect(completed.firstText == "Use option B.")
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
    func anthropicThinkingStreamsAndReplaysItsSignature() throws {
        var state = AnthropicStreamState()
        var events = AgentProviderClient.parseAnthropic(
            "content_block_start",
            ["index": 0, "content_block": ["type": "thinking", "thinking": ""]],
            state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_delta",
            ["index": 0, "delta": [
                "type": "thinking_delta", "thinking": "Inspect the logs.",
            ]], state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_delta",
            ["index": 0, "delta": [
                "type": "signature_delta", "signature": "signed-thinking",
            ]], state: &state
        )
        events += AgentProviderClient.parseAnthropic(
            "content_block_stop", ["index": 0], state: &state
        )

        #expect(events.firstReasoning == "Inspect the logs.")
        let item = try #require(events.firstProviderItem)
        #expect(item.objectValue?["thinking"]?.stringValue == "Inspect the logs.")
        #expect(item.objectValue?["signature"]?.stringValue == "signed-thinking")

        let assistant = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [AgentToolCall(
                id: "call", name: "lookup", arguments: .object([:])
            )],
            providerItems: [item]
        )
        let body = Self.body(
            ModelProvider(name: "Anthropic", kind: .anthropic),
            webSearch: false, tools: [], messages: [assistant]
        )
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages.first?["content"] as? [[String: Any]])
        let replayed = try #require(content.first { $0["type"] as? String == "thinking" })
        #expect(replayed["signature"] as? String == "signed-thinking")
    }

    @Test
    func anthropicBufferedThinkingIsNotAnswerText() {
        let events = AgentProviderClient.parseCompletedAnthropic([
            "type": "message",
            "content": [
                [
                    "type": "thinking", "thinking": "Checked disk usage.",
                    "signature": "signed",
                ],
                ["type": "text", "text": "The cache is largest."],
            ],
        ])

        #expect(events.firstReasoning == "Checked disk usage.")
        #expect(events.firstText == "The cache is largest.")
        #expect(events.firstProviderItem?.objectValue?["signature"]?.stringValue == "signed")
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

    @Test
    func googleThoughtTextIsReasoningAndFunctionSignatureReplays() throws {
        let events = AgentProviderClient.parseGoogle([
            "candidates": [[
                "content": ["parts": [
                    [
                        "thought": true, "text": "Check both hosts.",
                        "thoughtSignature": "thought-signature",
                    ],
                    ["text": "I found the issue."],
                    [
                        "thoughtSignature": "call-signature",
                        "functionCall": ["name": "lookup", "args": ["query": "disk"]],
                    ],
                ]],
                "finishReason": "STOP",
            ]],
        ])

        #expect(events.firstReasoning == "Check both hosts.")
        #expect(events.firstText == "I found the issue.")
        let tool = try #require(events.firstTool)
        #expect(tool.providerItemID == "call-signature")
        #expect(events.firstProviderItem?.objectValue?["thoughtSignature"]?.stringValue
            == "thought-signature")

        let assistant = AgentTranscriptMessage(
            role: .assistant,
            toolCalls: [AgentToolCall(
                id: tool.id, name: tool.name ?? "lookup", arguments: .object([:]),
                providerItemID: tool.providerItemID
            )]
        )
        let body = Self.body(
            ModelProvider(name: "Google", kind: .google),
            webSearch: false, tools: [], messages: [assistant]
        )
        let contents = try #require(body["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let replayedCall = try #require(parts.first { $0["functionCall"] != nil })
        #expect(replayedCall["thoughtSignature"] as? String == "call-signature")
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

    private static let namespacedTool = AgentToolDescriptor(
        name: "lookup", namespace: "a_b_c-d", summary: "Look something up.",
        inputSchema: .object([
            "type": .string("object"), "properties": .object([:]),
            "required": .array([]), "additionalProperties": .bool(false),
        ]),
        target: .mcp, safety: .requiresAuthorization
    )

    private static func reasoningModel(id: String) -> AIModel {
        var model = AIModel(id: id)
        model.abilities.insert(.reasoning)
        model.reasoningProfile = ReasoningProfile(levels: [
            .high: ReasoningLevelMapping(isSupported: true),
        ])
        return model
    }

    private static func body(
        _ provider: ModelProvider, webSearch: Bool, tools: [AgentToolDescriptor],
        messages: [AgentTranscriptMessage] = []
    ) -> [String: Any] {
        AgentProviderClient(
            provider: provider, model: AIModel(id: "model-test"), secret: "test",
            webSearch: webSearch
        ).body(AgentModelRequest(systemPrompt: "test", messages: messages, tools: tools))
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

    var firstTool: (
        id: String, providerItemID: String?, name: String?, arguments: String
    )? {
        for event in self {
            switch event {
            case .toolCallDelta(let id, let name, let arguments):
                return (id, nil, name, arguments)
            case .toolCallSnapshot(let id, let providerItemID, let name, let arguments):
                return (id, providerItemID, name, arguments)
            default: continue
            }
        }
        return nil
    }

    var firstReasoning: String? {
        for event in self {
            switch event {
            case .reasoningDelta(let text), .reasoningSnapshot(let text): return text
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

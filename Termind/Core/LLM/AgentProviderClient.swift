import Foundation

/// Provider-neutral streaming client. It keeps each provider's native message/tool
/// envelope at the boundary while exposing one event stream to AgentRuntime.
nonisolated struct AgentProviderClient: AgentModelStreaming, Sendable {
    private let provider: ModelProvider
    private let model: AIModel
    private let secret: String
    private let reasoning: ReasoningEffort
    private let session: URLSession

    init(
        provider: ModelProvider,
        model: AIModel,
        secret: String,
        reasoning: ReasoningEffort = .medium,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.model = model
        self.secret = secret
        self.reasoning = reasoning
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var chatCallIDs: [Int: String] = [:]
                    var anthropicCallIDs: [Int: String] = [:]
                    var responseCallIDs: [String: String] = [:]
                    var responseCallNames: [String: String] = [:]
                    var responseSawOutput = false
                    var urlRequest = try buildRequest(request)
                    try await authorize(&urlRequest)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw AgentProviderError.notHTTP
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw AgentProviderError.http(http.statusCode, String(decoding: data.prefix(4096), as: UTF8.self))
                    }
                    let contentType = http.value(forHTTPHeaderField: "Content-Type")?
                        .lowercased() ?? ""
                    if contentType.contains("application/json")
                        || contentType.contains("+json")
                    {
                        var data = Data()
                        for try await byte in bytes {
                            guard data.count < 16 * 1024 * 1024 else {
                                throw AgentProviderError.responseTooLarge
                            }
                            data.append(byte)
                        }
                        for item in try parseBufferedResponse(data) {
                            continuation.yield(item)
                        }
                        continuation.finish()
                        return
                    }
                    for try await event in SSEStream.events(from: bytes) {
                        if event.data == "[DONE]" { break }
                        for item in parse(
                            event, chatCallIDs: &chatCallIDs,
                            anthropicCallIDs: &anthropicCallIDs,
                            responseCallIDs: &responseCallIDs,
                            responseCallNames: &responseCallNames,
                            responseSawOutput: &responseSawOutput
                        ) {
                            continuation.yield(item)
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func buildRequest(_ input: AgentModelRequest) throws -> URLRequest {
        var urlString = provider.resolvedRequestURL(model: model.id)
        if provider.kind == .google {
            urlString = urlString.replacingOccurrences(
                of: ":generateContent", with: ":streamGenerateContent"
            )
            if !urlString.contains("alt=sse") {
                urlString += urlString.contains("?") ? "&alt=sse" : "?alt=sse"
            }
        }
        guard let url = URL(string: urlString) else {
            throw AgentProviderError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(input))
        return request
    }

    func body(_ request: AgentModelRequest) -> [String: Any] {
        let reasoningResolution = ModelCapabilityResolver.reasoning(
            model: model, provider: provider
        )
        let normalizedReasoning = reasoningResolution.clamp(reasoning)
        let reasoningValue = reasoningResolution.wireValue(for: normalizedReasoning)
        switch provider.kind {
        case .openAI where provider.usesResponsesAPI:
            let tools = request.tools.map(Self.openAIToolObject)
            var body: [String: Any] = [
                "model": model.id, "stream": true,
                "instructions": request.systemPrompt,
                "input": request.messages.flatMap(Self.responsesMessages),
            ]
            if !tools.isEmpty {
                body["tools"] = tools.map { tool in
                    var responseTool = tool
                    responseTool["type"] = "function"
                    return responseTool
                }
            }
            if let reasoningValue {
                body["reasoning"] = ["effort": reasoningValue]
            }
            return body
        case .openAI:
            let tools = request.tools.map(Self.openAIToolObject)
            var messages: [[String: Any]] = [["role": "system", "content": request.systemPrompt]]
            messages += request.messages.flatMap(Self.chatMessages)
            var body: [String: Any] = ["model": model.id, "stream": true, "messages": messages]
            if !tools.isEmpty { body["tools"] = tools.map { ["type": "function", "function": $0] } }
            if let reasoningValue { body["reasoning_effort"] = reasoningValue }
            return body
        case .anthropic:
            let tools = request.tools.map(Self.providerToolObject)
            var body: [String: Any] = [
                "model": model.id, "stream": true, "max_tokens": model.maxOutputTokens ?? 4096,
                "system": request.systemPrompt,
                "messages": request.messages.flatMap(Self.anthropicMessages),
            ]
            if !tools.isEmpty {
                body["tools"] = tools.map { tool in
                    ["name": tool["name"]!, "description": tool["description"]!, "input_schema": tool["parameters"]!]
                }
            }
            if let reasoningValue {
                body["output_config"] = ["effort": reasoningValue]
            }
            return body
        case .google:
            let tools = request.tools.map(Self.providerToolObject)
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": request.systemPrompt]]],
                "contents": request.messages.map(Self.googleMessage),
            ]
            if !tools.isEmpty { body["tools"] = [["functionDeclarations": tools]] }
            if let reasoningValue {
                body["generationConfig"] = [
                    "thinkingConfig": ["thinkingLevel": reasoningValue]
                ]
            }
            return body
        }
    }

    private func authorize(_ request: inout URLRequest) async throws {
        switch provider.kind {
        case .openAI: request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(secret, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .google:
            if provider.usesVertex {
                let token = try await GoogleServiceAccountAuth.shared.accessToken(serviceAccountJSON: secret)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            } else { request.setValue(secret, forHTTPHeaderField: "x-goog-api-key") }
        }
    }

    private func parse(
        _ event: SSEEvent, chatCallIDs: inout [Int: String],
        anthropicCallIDs: inout [Int: String],
        responseCallIDs: inout [String: String],
        responseCallNames: inout [String: String],
        responseSawOutput: inout Bool
    ) -> [AgentModelStreamEvent] {
        guard let data = event.data.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        // OpenAI's Responses stream normally puts the event discriminator in
        // the JSON payload (`type`) and leaves the SSE `event:` field unset.
        // Compatible gateways commonly do the same for every provider.
        let eventType = Self.streamEventType(event, root: root)
        switch provider.kind {
        case .openAI where provider.usesResponsesAPI:
            return Self.parseResponses(
                eventType, root, callIDs: &responseCallIDs,
                callNames: &responseCallNames,
                sawOutput: &responseSawOutput
            )
        case .openAI: return Self.parseChat(root, callIDs: &chatCallIDs)
        case .anthropic:
            return Self.parseAnthropic(eventType, root, callIDs: &anthropicCallIDs)
        case .google: return Self.parseGoogle(root)
        }
    }

    /// A number of OpenAI-compatible gateways accept `stream: true` but return
    /// one ordinary JSON response. Treat that as a valid completed stream.
    private func parseBufferedResponse(_ data: Data) throws -> [AgentModelStreamEvent] {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch provider.kind {
            case .openAI where provider.usesResponsesAPI:
                return Self.parseCompletedResponses(root)
            case .openAI:
                return Self.parseChat(root)
            case .anthropic:
                return Self.parseCompletedAnthropic(root)
            case .google:
                return Self.parseGoogle(root)
            }
        }

        // Some gateways label an SSE body as application/json. Fall back to
        // framing the already-buffered body rather than feeding `data: ...`
        // into JSONSerialization and surfacing Foundation's opaque error.
        var chatCallIDs: [Int: String] = [:]
        var anthropicCallIDs: [Int: String] = [:]
        var responseCallIDs: [String: String] = [:]
        var responseCallNames: [String: String] = [:]
        var responseSawOutput = false
        var output: [AgentModelStreamEvent] = []
        for event in SSEStream.events(in: data) where event.data != "[DONE]" {
            output += parse(
                event, chatCallIDs: &chatCallIDs,
                anthropicCallIDs: &anthropicCallIDs,
                responseCallIDs: &responseCallIDs,
                responseCallNames: &responseCallNames,
                responseSawOutput: &responseSawOutput
            )
        }
        guard !output.isEmpty else { throw AgentProviderError.invalidResponse }
        return output
    }

    private static func providerToolObject(_ descriptor: AgentToolDescriptor) -> [String: Any] {
        [
            "name": descriptor.name,
            "description": descriptor.summary,
            "parameters": foundationObject(descriptor.inputSchema),
        ]
    }

    static func streamEventType(_ event: SSEEvent, root: [String: Any]) -> String {
        event.event == "message" ? root["type"] as? String ?? event.event : event.event
    }

    private static func openAIToolObject(_ descriptor: AgentToolDescriptor) -> [String: Any] {
        [
            "name": descriptor.name,
            "description": descriptor.summary,
            "parameters": foundationObject(openAIStrictSchema(descriptor.inputSchema)),
            "strict": true,
        ]
    }

    /// OpenAI strict function schemas require every property to appear in
    /// `required`; semantic optionals are represented as nullable instead.
    /// Termind keeps its provider-neutral schema unchanged for local validation.
    static func openAIStrictSchema(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else { return schema }

        if let properties = object["properties"]?.objectValue {
            let originallyRequired = Set(
                object["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            )
            object["properties"] = .object(properties.reduce(into: [:]) { result, pair in
                let normalized = openAIStrictSchema(pair.value)
                result[pair.key] = originallyRequired.contains(pair.key)
                    ? normalized : nullable(normalized)
            })
            object["required"] = .array(properties.keys.sorted().map(AgentJSONValue.string))
            object["additionalProperties"] = .bool(false)
        }
        if let items = object["items"] { object["items"] = openAIStrictSchema(items) }
        if let variants = object["anyOf"]?.arrayValue {
            object["anyOf"] = .array(variants.map(openAIStrictSchema))
        }
        return .object(object)
    }

    private static func nullable(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else {
            return .object(["anyOf": .array([schema, .object(["type": .string("null")])])])
        }
        if let type = object["type"]?.stringValue {
            object["type"] = .array([.string(type), .string("null")])
            return .object(object)
        }
        if var types = object["type"]?.arrayValue {
            if !types.contains(.string("null")) { types.append(.string("null")) }
            object["type"] = .array(types)
            return .object(object)
        }
        if var variants = object["anyOf"]?.arrayValue {
            let nullType = AgentJSONValue.object(["type": .string("null")])
            if !variants.contains(nullType) { variants.append(nullType) }
            object["anyOf"] = .array(variants)
            return .object(object)
        }
        return .object(["anyOf": .array([.object(object), .object(["type": .string("null")])])])
    }

    private static func foundationObject(_ value: AgentJSONValue) -> Any {
        switch value {
        case .object(let value): value.mapValues(foundationObject)
        case .array(let value): value.map(foundationObject)
        case .string(let value): value
        case .number(let value): value
        case .bool(let value): value
        case .null: NSNull()
        }
    }

    private static func jsonValue(_ object: Any) -> AgentJSONValue? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? AgentJSONValue.decode(data)
    }

    private static func responsesMessages(_ message: AgentTranscriptMessage) -> [[String: Any]] {
        if message.role == .tool {
            return [["type": "function_call_output", "call_id": message.toolCallID ?? "", "output": message.text]]
        }
        var rows = message.providerItems.compactMap { foundationObject($0) as? [String: Any] }
        if !message.text.isEmpty {
            rows.append([
                "type": "message", "role": message.role.rawValue,
                "content": [["type": message.role == .assistant ? "output_text" : "input_text", "text": message.text]],
            ])
        }
        rows += message.toolCalls.map { call in
            var item: [String: Any] = [
                "type": "function_call", "call_id": call.id,
                "name": call.name, "arguments": call.arguments.encodedString,
            ]
            if let providerItemID = call.providerItemID { item["id"] = providerItemID }
            return item
        }
        return rows
    }

    private static func chatMessages(_ message: AgentTranscriptMessage) -> [[String: Any]] {
        if message.role == .tool {
            return [["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text]]
        }
        var row: [String: Any] = ["role": message.role.rawValue, "content": message.text]
        if !message.toolCalls.isEmpty {
            row["tool_calls"] = message.toolCalls.map {
                ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments.encodedString]]
            }
        }
        return [row]
    }

    private static func anthropicMessages(_ message: AgentTranscriptMessage) -> [[String: Any]] {
        if message.role == .tool {
            return [["role": "user", "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.text, "is_error": message.isError]]]]
        }
        var content: [[String: Any]] = message.text.isEmpty ? [] : [["type": "text", "text": message.text]]
        content += message.toolCalls.map { ["type": "tool_use", "id": $0.id, "name": $0.name, "input": foundationObject($0.arguments)] }
        return [["role": message.role == .assistant ? "assistant" : "user", "content": content]]
    }

    private static func googleMessage(_ message: AgentTranscriptMessage) -> [String: Any] {
        if message.role == .tool {
            return ["role": "user", "parts": [["functionResponse": ["name": message.toolName ?? "tool", "response": ["output": message.text]]]]]
        }
        var parts: [[String: Any]] = message.text.isEmpty ? [] : [["text": message.text]]
        parts += message.toolCalls.map { ["functionCall": ["name": $0.name, "args": foundationObject($0.arguments)]] }
        return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
    }

    static func parseResponses(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var callIDs: [String: String] = [:]
        var callNames: [String: String] = [:]
        var sawOutput = false
        return parseResponses(
            type, root, callIDs: &callIDs, callNames: &callNames,
            sawOutput: &sawOutput
        )
    }

    static func parseResponses(
        _ type: String, _ root: [String: Any],
        callIDs: inout [String: String], callNames: inout [String: String],
        sawOutput: inout Bool
    ) -> [AgentModelStreamEvent] {
        switch type {
        case "response.output_text.delta":
            let events: [AgentModelStreamEvent] = (root["delta"] as? String)
                .map { [.textDelta($0)] } ?? []
            sawOutput = sawOutput || !events.isEmpty
            return events
        case "response.function_call_arguments.delta":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            let name = root["name"] as? String ?? callNames[sourceID]
            callIDs[sourceID] = id
            if let name { callNames[sourceID] = name }
            sawOutput = true
            return [.toolCallDelta(
                id: id, name: name, arguments: root["delta"] as? String ?? ""
            )]
        case "response.function_call_arguments.done":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            guard let name = root["name"] as? String ?? callNames[sourceID] else {
                return []
            }
            sawOutput = true
            return [.toolCallSnapshot(
                id: id, providerItemID: sourceID, name: name,
                arguments: root["arguments"] as? String ?? ""
            )]
        case "response.output_item.added":
            guard let item = root["item"] as? [String: Any], item["type"] as? String == "function_call",
                let sourceID = (item["id"] ?? item["call_id"]) as? String
            else { return [] }
            let id = item["call_id"] as? String ?? sourceID
            callIDs[sourceID] = id
            if let name = item["name"] as? String { callNames[sourceID] = name }
            sawOutput = true
            return [.toolCallDelta(
                id: id, name: item["name"] as? String,
                arguments: item["arguments"] as? String ?? ""
            )]
        case "response.output_item.done":
            guard let item = root["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "reasoning",
                let value = jsonValue(item)
            {
                sawOutput = true
                return [.providerItem(value)]
            }
            guard item["type"] as? String == "function_call",
                let sourceID = (item["id"] ?? item["call_id"]) as? String,
                let name = item["name"] as? String ?? callNames[sourceID]
            else { return [] }
            let id = item["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            callNames[sourceID] = name
            sawOutput = true
            return [.toolCallSnapshot(
                id: id, providerItemID: item["id"] as? String,
                name: name,
                arguments: item["arguments"] as? String ?? ""
            )]
        case "response.completed":
            if root["response"] is [String: Any] || root["output"] is [[String: Any]] {
                let events = parseCompletedResponses(root)
                sawOutput = events.containsToolCall || events.containsText
                return events
            }
            return [.finished(.completed)]
        case "response.incomplete": return [.finished(.length)]
        case "response.failed": return [.finished(.error)]
        default:
            // Some compatible servers put the complete Responses object in one
            // unnamed SSE `data:` event instead of using typed delta events.
            guard root["object"] as? String == "response" else { return [] }
            let events = parseCompletedResponses(root)
            sawOutput = events.containsToolCall || events.containsText
            return events
        }
    }

    static func parseCompletedResponses(
        _ root: [String: Any]
    ) -> [AgentModelStreamEvent] {
        let response = root["response"] as? [String: Any] ?? root
        guard response["object"] as? String == "response"
            || response["output"] is [[String: Any]]
        else { return [] }

        var events: [AgentModelStreamEvent] = []
        var completedText = ""
        for item in response["output"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "reasoning":
                if let value = jsonValue(item) { events.append(.providerItem(value)) }
            case "message":
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text",
                        let text = content["text"] as? String
                    {
                        completedText += text
                    }
                }
            case "function_call":
                guard let name = item["name"] as? String else { continue }
                let id = (item["call_id"] ?? item["id"]) as? String
                    ?? UUID().uuidString
                events.append(.toolCallSnapshot(
                    id: id, providerItemID: item["id"] as? String,
                    name: name,
                    arguments: item["arguments"] as? String ?? ""
                ))
            default: continue
            }
        }
        if !completedText.isEmpty { events.append(.textSnapshot(completedText)) }
        let status = response["status"] as? String
        let reason: AgentStopReason
        if status == "incomplete" { reason = .length }
        else if status == "failed" { reason = .error }
        else { reason = events.containsToolCall ? .toolCalls : .completed }
        events.append(.finished(reason))
        return events
    }

    static func parseChat(_ root: [String: Any]) -> [AgentModelStreamEvent] {
        var callIDs: [Int: String] = [:]
        return parseChat(root, callIDs: &callIDs)
    }

    static func parseChat(
        _ root: [String: Any], callIDs: inout [Int: String]
    ) -> [AgentModelStreamEvent] {
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return [] }
        var events: [AgentModelStreamEvent] = []
        if let message = choice["message"] as? [String: Any] {
            if let text = message["content"] as? String { events.append(.textDelta(text)) }
            for (index, call) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let function = call["function"] as? [String: Any]
                guard let name = function?["name"] as? String else { continue }
                events.append(.toolCallDelta(
                    id: call["id"] as? String ?? "index-\(index)", name: name,
                    arguments: function?["arguments"] as? String ?? ""
                ))
            }
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String { events.append(.textDelta(text)) }
            for call in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let index = call["index"] as? Int ?? 0
                if let id = call["id"] as? String { callIDs[index] = id }
                let function = call["function"] as? [String: Any]
                events.append(.toolCallDelta(
                    id: callIDs[index] ?? "index-\(index)",
                    name: function?["name"] as? String,
                    arguments: function?["arguments"] as? String ?? ""
                ))
            }
        }
        if let reason = choice["finish_reason"] as? String {
            events.append(.finished(reason == "length" ? .length : reason == "tool_calls" ? .toolCalls : .completed))
        } else if choice["message"] != nil {
            events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        }
        return events
    }

    static func parseCompletedAnthropic(_ root: [String: Any]) -> [AgentModelStreamEvent] {
        guard root["type"] as? String == "message" else { return [] }
        var events: [AgentModelStreamEvent] = []
        for block in root["content"] as? [[String: Any]] ?? [] {
            if block["type"] as? String == "text", let text = block["text"] as? String {
                events.append(.textDelta(text))
            } else if block["type"] as? String == "tool_use",
                let name = block["name"] as? String
            {
                let data = block["input"].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                } ?? Data("{}".utf8)
                events.append(.toolCallDelta(
                    id: block["id"] as? String ?? UUID().uuidString,
                    name: name, arguments: String(decoding: data, as: UTF8.self)
                ))
            }
        }
        events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        return events
    }

    static func parseAnthropic(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var callIDs: [Int: String] = [:]
        return parseAnthropic(type, root, callIDs: &callIDs)
    }

    static func parseAnthropic(
        _ type: String, _ root: [String: Any], callIDs: inout [Int: String]
    ) -> [AgentModelStreamEvent] {
        if type == "content_block_start", let block = root["content_block"] as? [String: Any],
            block["type"] as? String == "tool_use"
        {
            let index = root["index"] as? Int ?? 0
            let id = block["id"] as? String ?? "index-\(index)"
            callIDs[index] = id
            return [.toolCallDelta(
                id: id,
                name: block["name"] as? String, arguments: ""
            )]
        }
        if type == "content_block_delta", let delta = root["delta"] as? [String: Any] {
            if let text = delta["text"] as? String { return [.textDelta(text)] }
            if let json = delta["partial_json"] as? String {
                let index = root["index"] as? Int ?? 0
                return [.toolCallDelta(
                    id: callIDs[index] ?? "index-\(index)", name: nil, arguments: json
                )]
            }
        }
        if type == "message_stop" { return [.finished(.completed)] }
        return []
    }

    static func parseGoogle(_ root: [String: Any]) -> [AgentModelStreamEvent] {
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first,
            let content = candidate["content"] as? [String: Any]
        else { return [] }
        var events: [AgentModelStreamEvent] = []
        for part in content["parts"] as? [[String: Any]] ?? [] {
            if let text = part["text"] as? String { events.append(.textDelta(text)) }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let args = call["args"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
                events.append(.toolCallDelta(id: UUID().uuidString, name: name, arguments: String(decoding: args, as: UTF8.self)))
            }
        }
        if candidate["finishReason"] != nil { events.append(.finished(events.containsToolCall ? .toolCalls : .completed)) }
        return events
    }
}

nonisolated private extension Array where Element == AgentModelStreamEvent {
    var containsToolCall: Bool {
        contains {
            switch $0 {
            case .toolCallDelta, .toolCallSnapshot: true
            default: false
            }
        }
    }

    var containsText: Bool {
        contains {
            switch $0 {
            case .textDelta, .textSnapshot: true
            default: false
            }
        }
    }
}

nonisolated enum AgentProviderError: LocalizedError, Sendable {
    case badURL, notHTTP, invalidResponse, responseTooLarge, http(Int, String)
    var errorDescription: String? {
        switch self {
        case .badURL: String(localized: "The model endpoint URL is invalid.")
        case .notHTTP: String(localized: "The model endpoint did not return HTTP.")
        case .invalidResponse: String(localized: "The model endpoint returned an unsupported response format.")
        case .responseTooLarge: String(localized: "The model response exceeded Termind's size limit.")
        case .http(let status, let body): String(localized: "The model endpoint returned \(status): \(body)")
        }
    }
}

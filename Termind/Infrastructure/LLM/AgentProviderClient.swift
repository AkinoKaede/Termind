import Foundation

/// Reversible names for providers whose tool protocols have no namespace field.
nonisolated struct AgentProviderToolNameMap: Sendable {
    var qualifiedToWire: [String: String]
    var wireToQualified: [String: String]

    static func flat(_ descriptors: [AgentToolDescriptor]) -> Self {
        var qualifiedToWire: [String: String] = [:]
        var wireToQualified: [String: String] = [:]
        var taken = Set<String>()
        let builtIns = descriptors.filter { $0.namespace == nil }
            .sorted { $0.name < $1.name }
        for descriptor in builtIns {
            taken.insert(descriptor.name)
            qualifiedToWire[descriptor.qualifiedName] = descriptor.name
            wireToQualified[descriptor.name] = descriptor.qualifiedName
        }
        let namespaced = descriptors.filter { $0.namespace != nil }
            .sorted { $0.qualifiedName < $1.qualifiedName }
        for descriptor in namespaced {
            let base = "mcp__\(descriptor.namespace!)__\(descriptor.name)"
            var wire = base
            var suffix = 2
            while taken.contains(wire) {
                wire = "\(base)_\(suffix)"
                suffix += 1
            }
            taken.insert(wire)
            qualifiedToWire[descriptor.qualifiedName] = wire
            wireToQualified[wire] = descriptor.qualifiedName
        }
        return Self(qualifiedToWire: qualifiedToWire, wireToQualified: wireToQualified)
    }

    func wireName(for qualifiedName: String) -> String {
        if let wire = qualifiedToWire[qualifiedName] { return wire }
        guard let separator = qualifiedName.firstIndex(of: ".") else {
            return qualifiedName
        }
        let namespace = qualifiedName[..<separator]
        let name = qualifiedName[qualifiedName.index(after: separator)...]
        return "mcp__\(namespace)__\(name)"
    }

    func qualifiedName(for wireName: String) -> String {
        wireToQualified[wireName] ?? wireName
    }
}

/// Provider-neutral streaming client. It keeps each provider's native message/tool
/// envelope at the boundary while exposing one event stream to AgentRuntime.
nonisolated struct AgentProviderClient: AgentModelStreaming, Sendable {
    private let provider: ModelProvider
    private let model: AIModel
    private let secret: String
    private let reasoning: ReasoningEffort
    /// Ask the provider to run web search on its own servers this turn.
    ///
    /// Off by default so the short, tool-free features — titling, the command
    /// composer, Security Review — cannot acquire it by accident. Only the
    /// Chat/Agent path sets it, and only after `AppModel` has checked both the
    /// model's ability and `ModelProvider.supportsNativeWebSearch`.
    private let webSearch: Bool
    private let session: URLSession

    init(
        provider: ModelProvider,
        model: AIModel,
        secret: String,
        reasoning: ReasoningEffort = .medium,
        webSearch: Bool = false,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.model = model
        self.secret = secret
        self.reasoning = reasoning
        self.webSearch = webSearch
        self.session = session ?? Self.shared
    }

    /// One session for every agent request.
    ///
    /// A `URLSession` keeps itself alive until it is invalidated, and a client
    /// is built per run — and again per Security Review — so making one here
    /// leaked a session, its connection pool, and its delegate queue on every
    /// turn. Sharing it also lets a multi-turn run reuse the connection it
    /// already has open.
    private static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let toolNames = AgentProviderToolNameMap.flat(request.tools)
                    var chatCallIDs: [Int: String] = [:]
                    var anthropicState = AnthropicStreamState()
                    var responseCallIDs: [String: String] = [:]
                    var responseCallNames: [String: String] = [:]
                    var urlRequest = try buildRequest(request, streaming: true)
                    try await authorize(&urlRequest)
                    let (bytes, response) = try await session.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else {
                        throw AgentProviderError.notHTTP
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        throw AgentProviderError.http(
                            http.statusCode, await Self.errorBody(bytes)
                        )
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
                        for item in try parseBufferedResponse(
                            data, wireNames: toolNames.wireToQualified
                        ) {
                            continuation.yield(item)
                        }
                        continuation.finish()
                        return
                    }
                    for try await event in SSEStream.events(from: bytes) {
                        if event.data == "[DONE]" { break }
                        for item in try parse(
                            event, chatCallIDs: &chatCallIDs,
                            anthropicState: &anthropicState,
                            responseCallIDs: &responseCallIDs,
                            responseCallNames: &responseCallNames,
                            wireNames: toolNames.wireToQualified
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

    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent] {
        let toolNames = AgentProviderToolNameMap.flat(request.tools)
        var urlRequest = try buildRequest(request, streaming: false)
        try await authorize(&urlRequest)
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AgentProviderError.notHTTP
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 16 * 1024 * 1024 else {
                throw AgentProviderError.responseTooLarge
            }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentProviderError.http(
                http.statusCode, String(decoding: data.prefix(4096), as: UTF8.self)
            )
        }
        return try parseBufferedResponse(data, wireNames: toolNames.wireToQualified)
    }

    /// Reads only as much of a failed response as the message will show.
    ///
    /// The success paths are capped; this one drained the whole body first and
    /// then took its first 4 KB, so a gateway answering an error with an endless
    /// stream could be read until the process ran out of memory.
    private static func errorBody<Bytes: AsyncSequence & Sendable>(
        _ bytes: Bytes
    ) async -> String where Bytes.Element == UInt8 {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 4_096 { break }
            }
        } catch {
            // A truncated error body still describes the failure better than
            // the transport error that interrupted reading it.
        }
        return String(decoding: data, as: UTF8.self)
    }

    func buildRequest(
        _ input: AgentModelRequest, streaming: Bool
    ) throws -> URLRequest {
        var urlString = provider.resolvedRequestURL(model: model.id)
        if provider.kind == .google, streaming {
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
        request.setValue(
            streaming ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body(input, streaming: streaming)
        )
        return request
    }

    func body(_ request: AgentModelRequest) -> [String: Any] {
        body(request, streaming: true)
    }

    func body(
        _ request: AgentModelRequest, streaming: Bool
    ) -> [String: Any] {
        let toolNames = AgentProviderToolNameMap.flat(request.tools)
        let reasoningResolution = ModelCapabilityResolver.reasoning(
            model: model, provider: provider
        )
        let normalizedReasoning = reasoningResolution.clamp(reasoning)
        let reasoningValue = reasoningResolution.wireValue(for: normalizedReasoning)
        switch provider.kind {
        case .openAI where provider.usesResponsesAPI:
            var tools = Self.responsesToolObjects(request.tools)
            if webSearch { tools.append(["type": "web_search"]) }
            var body: [String: Any] = [
                "model": model.id, "stream": streaming,
                "instructions": request.systemPrompt,
                "input": request.messages.flatMap(Self.responsesMessages),
            ]
            if !tools.isEmpty { body["tools"] = tools }
            if let reasoningValue {
                body["reasoning"] = ["effort": reasoningValue, "summary": "auto"]
            }
            return body
        case .openAI:
            // No search here, whatever the model claims. `web_search_options`
            // exists on two `*-search-preview` SKUs, while this branch is also
            // every OpenAI-compatible gateway Termind talks to — see
            // `ModelProvider.supportsNativeWebSearch`, which is what actually
            // prevents it reaching this far.
            let tools = request.tools.map {
                Self.openAIToolObject($0, name: toolNames.wireName(for: $0.qualifiedName))
            }
            var messages: [[String: Any]] = [["role": "system", "content": request.systemPrompt]]
            messages += request.messages.flatMap {
                Self.chatMessages($0, toolNames: toolNames)
            }
            var body: [String: Any] = [
                "model": model.id, "stream": streaming, "messages": messages,
            ]
            // The one provider that has to be asked for its own token counts.
            // Responses, Anthropic and Gemini report usage unconditionally;
            // Chat Completions omits it from a stream unless this is present.
            // Only on the streaming path — sending it on a non-streaming request
            // is what several OpenAI-compatible gateways reject outright.
            if streaming { body["stream_options"] = ["include_usage": true] }
            if !tools.isEmpty { body["tools"] = tools.map { ["type": "function", "function": $0] } }
            if let reasoningValue { body["reasoning_effort"] = reasoningValue }
            return body
        case .anthropic:
            var tools: [[String: Any]] = request.tools.map {
                Self.providerToolObject($0, name: toolNames.wireName(for: $0.qualifiedName))
            }.map { tool in
                ["name": tool["name"]!, "description": tool["description"]!, "input_schema": tool["parameters"]!]
            }
            if webSearch {
                tools.append([
                    "type": "web_search_20250305", "name": "web_search",
                    "max_uses": Self.nativeWebSearchMaxUses,
                ])
            }
            var body: [String: Any] = [
                "model": model.id, "stream": streaming,
                "max_tokens": model.maxOutputTokens ?? 4096,
                "system": request.systemPrompt,
                "messages": request.messages.flatMap {
                    Self.anthropicMessages($0, toolNames: toolNames)
                },
            ]
            if !tools.isEmpty { body["tools"] = tools }
            if let reasoningValue {
                body["output_config"] = ["effort": reasoningValue]
                if Self.supportsAdaptiveAnthropicThinking(model.id) {
                    body["thinking"] = [
                        "type": "adaptive", "display": "summarized",
                    ]
                }
            }
            return body
        case .google:
            let declarations = request.tools.map {
                Self.providerToolObject($0, name: toolNames.wireName(for: $0.qualifiedName))
            }
            // Two entries, not two keys in one entry. Gemini's `tools` is a
            // list of tool *groups*, and putting `google_search` beside
            // `functionDeclarations` inside one object is the arrangement it
            // rejects.
            var tools: [[String: Any]] = []
            if !declarations.isEmpty { tools.append(["functionDeclarations": declarations]) }
            if webSearch { tools.append(["google_search": [String: Any]()]) }
            var body: [String: Any] = [
                "systemInstruction": ["parts": [["text": request.systemPrompt]]],
                "contents": request.messages.map {
                    Self.googleMessage($0, toolNames: toolNames)
                },
            ]
            if !tools.isEmpty { body["tools"] = tools }
            if let reasoningValue {
                body["generationConfig"] = [
                    "thinkingConfig": [
                        "thinkingLevel": reasoningValue,
                        "includeThoughts": true,
                    ]
                ]
            }
            return body
        }
    }

    /// A ceiling on searches per turn, which only Anthropic's tool takes as a
    /// parameter. Eight is enough for a model to refine a query a few times and
    /// low enough that a loop costs a bounded number of billed searches.
    static let nativeWebSearchMaxUses = 8

    /// Adaptive thinking and effort are one protocol on current Claude
    /// families. Older extended-thinking models use a token budget instead;
    /// inventing that budget from this app's qualitative effort control would
    /// silently change cost, so those models keep their existing request shape.
    private static func supportsAdaptiveAnthropicThinking(_ modelID: String) -> Bool {
        modelID.lowercased().range(
            of: #"claude-(opus|sonnet|haiku)-(4[-.]([6-9])|[5-9])"#,
            options: .regularExpression
        ) != nil
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
        anthropicState: inout AnthropicStreamState,
        responseCallIDs: inout [String: String],
        responseCallNames: inout [String: String],
        wireNames: [String: String]
    ) throws -> [AgentModelStreamEvent] {
        guard let data = event.data.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        // OpenAI's Responses stream normally puts the event discriminator in
        // the JSON payload (`type`) and leaves the SSE `event:` field unset.
        // Compatible gateways commonly do the same for every provider.
        let eventType = Self.streamEventType(event, root: root)
        switch provider.kind {
        case .openAI where provider.usesResponsesAPI:
            if eventType == "response.completed",
                root["response"] as? [String: Any] == nil
            {
                throw AgentProviderError.invalidResponse
            }
            return Self.parseResponses(
                eventType, root, callIDs: &responseCallIDs,
                callNames: &responseCallNames
            )
        case .openAI:
            return Self.parseChat(root, callIDs: &chatCallIDs, wireNames: wireNames)
        case .anthropic:
            return Self.parseAnthropic(
                eventType, root, state: &anthropicState, wireNames: wireNames
            )
        case .google: return Self.parseGoogle(root, wireNames: wireNames)
        }
    }

    /// A number of OpenAI-compatible gateways accept `stream: true` but return
    /// one ordinary JSON response. Treat that as a valid completed stream.
    private func parseBufferedResponse(
        _ data: Data, wireNames: [String: String]
    ) throws -> [AgentModelStreamEvent] {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch provider.kind {
            case .openAI where provider.usesResponsesAPI:
                return Self.parseCompletedResponses(root)
            case .openAI:
                return Self.parseChat(root, wireNames: wireNames)
            case .anthropic:
                return Self.parseCompletedAnthropic(root, wireNames: wireNames)
            case .google:
                return Self.parseGoogle(root, wireNames: wireNames)
            }
        }

        // Some gateways label an SSE body as application/json. Fall back to
        // framing the already-buffered body rather than feeding `data: ...`
        // into JSONSerialization and surfacing Foundation's opaque error.
        var chatCallIDs: [Int: String] = [:]
        var anthropicState = AnthropicStreamState()
        var responseCallIDs: [String: String] = [:]
        var responseCallNames: [String: String] = [:]
        var output: [AgentModelStreamEvent] = []
        for event in SSEStream.events(in: data) where event.data != "[DONE]" {
            output += try parse(
                event, chatCallIDs: &chatCallIDs,
                anthropicState: &anthropicState,
                responseCallIDs: &responseCallIDs,
                responseCallNames: &responseCallNames,
                wireNames: wireNames
            )
        }
        guard !output.isEmpty else { throw AgentProviderError.invalidResponse }
        return output
    }

    private static func providerToolObject(
        _ descriptor: AgentToolDescriptor, name: String
    ) -> [String: Any] {
        [
            "name": name,
            "description": descriptor.summary,
            "parameters": foundationObject(descriptor.inputSchema),
        ]
    }

    static func streamEventType(_ event: SSEEvent, root: [String: Any]) -> String {
        event.event == "message" ? root["type"] as? String ?? event.event : event.event
    }

    private static func openAIToolObject(
        _ descriptor: AgentToolDescriptor, name: String? = nil
    ) -> [String: Any] {
        [
            "name": name ?? descriptor.name,
            "description": descriptor.summary,
            "parameters": foundationObject(openAIStrictSchema(descriptor.inputSchema)),
            "strict": true,
        ]
    }

    private static func responsesToolObjects(
        _ descriptors: [AgentToolDescriptor]
    ) -> [[String: Any]] {
        var tools = descriptors.filter { $0.namespace == nil }.map { descriptor in
            var tool = openAIToolObject(descriptor)
            tool["type"] = "function"
            return tool
        }
        let grouped = Dictionary(grouping: descriptors.compactMap { descriptor in
            descriptor.namespace.map { ($0, descriptor) }
        }, by: { $0.0 })
        for namespace in grouped.keys.sorted() {
            let members = (grouped[namespace] ?? []).map(\.1)
                .sorted { $0.name < $1.name }
            let children = members.map { descriptor -> [String: Any] in
                var tool = openAIToolObject(descriptor)
                tool["type"] = "function"
                return tool
            }
            tools.append([
                "type": "namespace", "name": namespace, "tools": children,
            ])
        }
        return tools
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
        if !message.text.isEmpty || !message.images.isEmpty {
            var content: [[String: Any]] = []
            if !message.text.isEmpty {
                content.append([
                    "type": message.role == .assistant ? "output_text" : "input_text",
                    "text": message.text,
                ])
            }
            if message.role == .user {
                content += message.images.map {
                    ["type": "input_image", "image_url": dataURI(for: $0)]
                }
            }
            rows.append([
                "type": "message", "role": message.role.rawValue,
                "content": content,
            ])
        }
        rows += message.toolCalls.map { call in
            let parts = splitQualifiedName(call.name)
            var item: [String: Any] = [
                "type": "function_call", "call_id": call.id,
                "name": parts.name, "arguments": call.arguments.encodedString,
            ]
            if let namespace = parts.namespace { item["namespace"] = namespace }
            if let providerItemID = call.providerItemID { item["id"] = providerItemID }
            return item
        }
        return rows
    }

    private static func chatMessages(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [[String: Any]] {
        if message.role == .tool {
            return [["role": "tool", "tool_call_id": message.toolCallID ?? "", "content": message.text]]
        }
        var row: [String: Any] = ["role": message.role.rawValue]
        if message.role == .user, !message.images.isEmpty {
            var content: [[String: Any]] = []
            if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
            content += message.images.map {
                ["type": "image_url", "image_url": ["url": dataURI(for: $0)]]
            }
            row["content"] = content
        } else {
            row["content"] = message.text
        }
        if !message.toolCalls.isEmpty {
            row["tool_calls"] = message.toolCalls.map {
                ["id": $0.id, "type": "function", "function": [
                    "name": toolNames.wireName(for: $0.name),
                    "arguments": $0.arguments.encodedString,
                ]]
            }
        }
        return [row]
    }

    private static func anthropicMessages(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [[String: Any]] {
        if message.role == .tool {
            return [["role": "user", "content": [["type": "tool_result", "tool_use_id": message.toolCallID ?? "", "content": message.text, "is_error": message.isError]]]]
        }
        var content = message.providerItems.compactMap { item -> [String: Any]? in
            guard let row = foundationObject(item) as? [String: Any],
                let type = row["type"] as? String,
                type == "thinking" || type == "redacted_thinking"
            else { return nil }
            return row
        }
        if !message.text.isEmpty { content.append(["type": "text", "text": message.text]) }
        if message.role == .user {
            content += message.images.map { image in
                [
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": image.mimeType,
                        "data": image.data.base64EncodedString(),
                    ],
                ]
            }
        }
        content += message.toolCalls.map { [
            "type": "tool_use", "id": $0.id,
            "name": toolNames.wireName(for: $0.name),
            "input": foundationObject($0.arguments),
        ] }
        return [["role": message.role == .assistant ? "assistant" : "user", "content": content]]
    }

    private static func googleMessage(
        _ message: AgentTranscriptMessage, toolNames: AgentProviderToolNameMap
    ) -> [String: Any] {
        if message.role == .tool {
            return ["role": "user", "parts": [["functionResponse": [
                "name": toolNames.wireName(for: message.toolName ?? "tool"),
                "response": ["output": message.text],
            ]]]]
        }
        var parts = message.providerItems.compactMap { item -> [String: Any]? in
            guard let row = foundationObject(item) as? [String: Any],
                row["thought"] as? Bool == true
            else { return nil }
            return row
        }
        if !message.text.isEmpty { parts.append(["text": message.text]) }
        if message.role == .user {
            parts += message.images.map { image in
                ["inlineData": [
                    "mimeType": image.mimeType,
                    "data": image.data.base64EncodedString(),
                ]]
            }
        }
        parts += message.toolCalls.map { call in
            var part: [String: Any] = ["functionCall": [
                "name": toolNames.wireName(for: call.name),
                "args": foundationObject(call.arguments),
            ]]
            if let signature = call.providerItemID {
                part["thoughtSignature"] = signature
            }
            return part
        }
        return ["role": message.role == .assistant ? "model" : "user", "parts": parts]
    }

    private static func splitQualifiedName(
        _ qualifiedName: String
    ) -> (namespace: String?, name: String) {
        guard let separator = qualifiedName.firstIndex(of: ".") else {
            return (nil, qualifiedName)
        }
        return (
            String(qualifiedName[..<separator]),
            String(qualifiedName[qualifiedName.index(after: separator)...])
        )
    }

    private static func dataURI(for image: AgentImageAttachment) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }

    private static func responseName(_ object: [String: Any]) -> String? {
        guard let name = object["name"] as? String else { return nil }
        guard let namespace = object["namespace"] as? String, !namespace.isEmpty else {
            return name
        }
        return "\(namespace).\(name)"
    }

    private static func responsesReasoningSummary(_ item: [String: Any]) -> String? {
        let parts = item["summary"] as? [[String: Any]] ?? []
        let text = parts.compactMap { part -> String? in
            guard part["type"] as? String == "summary_text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    private static func canonicalName(
        _ wireName: String, wireNames: [String: String]
    ) -> String {
        wireNames[wireName] ?? wireName
    }

    static func parseResponses(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var callIDs: [String: String] = [:]
        var callNames: [String: String] = [:]
        return parseResponses(
            type, root, callIDs: &callIDs, callNames: &callNames
        )
    }

    static func parseResponses(
        _ type: String, _ root: [String: Any],
        callIDs: inout [String: String], callNames: inout [String: String]
    ) -> [AgentModelStreamEvent] {
        switch type {
        case "response.output_text.delta":
            let events: [AgentModelStreamEvent] = (root["delta"] as? String)
                .map { [.textDelta($0)] } ?? []
            return events
        case "response.reasoning_summary_text.delta":
            return (root["delta"] as? String).map { [.reasoningDelta($0)] } ?? []
        case "response.reasoning_summary_text.done":
            return (root["text"] as? String).map { [.reasoningSnapshot($0)] } ?? []
        case "response.function_call_arguments.delta":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            let name = responseName(root) ?? callNames[sourceID]
            callIDs[sourceID] = id
            if let name { callNames[sourceID] = name }
            return [.toolCallDelta(
                id: id, name: name, arguments: root["delta"] as? String ?? ""
            )]
        case "response.function_call_arguments.done":
            guard let sourceID = (root["item_id"] ?? root["call_id"]) as? String else {
                return []
            }
            let id = root["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            guard let name = responseName(root) ?? callNames[sourceID] else {
                return []
            }
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
            if let name = responseName(item) { callNames[sourceID] = name }
            return [.toolCallDelta(
                id: id, name: responseName(item),
                arguments: item["arguments"] as? String ?? ""
            )]
        case "response.output_item.done":
            guard let item = root["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "reasoning",
                let value = jsonValue(item)
            {
                var events: [AgentModelStreamEvent] = [.providerItem(value)]
                if let summary = responsesReasoningSummary(item), !summary.isEmpty {
                    events.append(.reasoningSnapshot(summary))
                }
                return events
            }
            if item["type"] as? String == "web_search_call" {
                return responsesWebSearch(item)
            }
            guard item["type"] as? String == "function_call",
                let sourceID = (item["id"] ?? item["call_id"]) as? String,
                let name = responseName(item) ?? callNames[sourceID]
            else { return [] }
            let id = item["call_id"] as? String ?? callIDs[sourceID] ?? sourceID
            callIDs[sourceID] = id
            callNames[sourceID] = name
            return [.toolCallSnapshot(
                id: id, providerItemID: item["id"] as? String,
                name: name,
                arguments: item["arguments"] as? String ?? ""
            )]
        case "response.completed":
            guard root["response"] is [String: Any] else { return [] }
            return parseCompletedResponses(root)
        case "response.incomplete": return [.finished(.length)]
        case "response.failed": return [.finished(.error)]
        default:
            // Some compatible servers put the complete Responses object in one
            // unnamed SSE `data:` event instead of using typed delta events.
            guard root["object"] as? String == "response" else { return [] }
            let events = parseCompletedResponses(root)
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
                if let summary = responsesReasoningSummary(item), !summary.isEmpty {
                    events.append(.reasoningSnapshot(summary))
                }
            case "web_search_call":
                events += responsesWebSearch(item)
            case "message":
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text",
                        let text = content["text"] as? String
                    {
                        completedText += text
                    }
                }
            case "function_call":
                guard let name = responseName(item) else { continue }
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
        if let usage = responsesUsage(response) { events.append(usage) }
        let status = response["status"] as? String
        let reason: AgentStopReason
        if status == "incomplete" { reason = .length }
        else if status == "failed" { reason = .error }
        else { reason = events.containsToolCall ? .toolCalls : .completed }
        events.append(.finished(reason))
        return events
    }

    static func parseChat(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        var callIDs: [Int: String] = [:]
        return parseChat(root, callIDs: &callIDs, wireNames: wireNames)
    }

    static func parseChat(
        _ root: [String: Any], callIDs: inout [Int: String],
        wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        // Before the `choices` guard, not after it. With `stream_options`
        // requested, OpenAI sends usage on a final chunk whose `choices` is an
        // empty array — the one chunk that carries the number would otherwise be
        // the one chunk this parser drops on the floor.
        var events: [AgentModelStreamEvent] = chatUsage(root).map { [$0] } ?? []
        guard let choice = (root["choices"] as? [[String: Any]])?.first else { return events }
        if let message = choice["message"] as? [String: Any] {
            if let text = message["content"] as? String { events.append(.textDelta(text)) }
            for (index, call) in (message["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
                let function = call["function"] as? [String: Any]
                guard let name = function?["name"] as? String else { continue }
                events.append(.toolCallDelta(
                    id: call["id"] as? String ?? "index-\(index)",
                    name: canonicalName(name, wireNames: wireNames),
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
                    name: (function?["name"] as? String).map {
                        canonicalName($0, wireNames: wireNames)
                    },
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

    static func parseCompletedAnthropic(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        guard root["type"] as? String == "message" else { return [] }
        var events: [AgentModelStreamEvent] = []
        // The buffered body has both halves of a search in hand, so the query
        // is matched to its results here rather than parked across events the
        // way the streaming parser has to.
        var queries: [String: String] = [:]
        for block in root["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "thinking":
                if let thinking = block["thinking"] as? String, !thinking.isEmpty {
                    events.append(.reasoningDelta(thinking))
                }
                if let value = jsonValue(block) { events.append(.providerItem(value)) }
            case "redacted_thinking":
                if let value = jsonValue(block) { events.append(.providerItem(value)) }
            case "text":
                if let text = block["text"] as? String { events.append(.textDelta(text)) }
            case "tool_use":
                guard let name = block["name"] as? String else { continue }
                let data = block["input"].flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                } ?? Data("{}".utf8)
                events.append(.toolCallDelta(
                    id: block["id"] as? String ?? UUID().uuidString,
                    name: canonicalName(name, wireNames: wireNames),
                    arguments: String(decoding: data, as: UTF8.self)
                ))
            case "server_tool_use":
                guard let id = block["id"] as? String else { continue }
                queries[id] = (block["input"] as? [String: Any])?["query"] as? String ?? ""
            case "web_search_tool_result":
                let query = (block["tool_use_id"] as? String).flatMap { queries[$0] }
                events.append(.webSearch(AgentWebSearchActivity(
                    query: query ?? "", sources: anthropicSources(block["content"])
                )))
            default:
                continue
            }
        }
        if let usage = anthropicUsage(root["usage"]) { events.append(usage) }
        events.append(.finished(events.containsToolCall ? .toolCalls : .completed))
        return events
    }

    static func parseAnthropic(_ type: String, _ root: [String: Any]) -> [AgentModelStreamEvent] {
        var state = AnthropicStreamState()
        return parseAnthropic(type, root, state: &state, wireNames: [:])
    }

    static func parseAnthropic(
        _ type: String, _ root: [String: Any], state: inout AnthropicStreamState,
        wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        let index = root["index"] as? Int ?? 0

        // Anthropic splits one turn's count across two events: input arrives
        // with `message_start`, output grows on each `message_delta`. Both are
        // cumulative, which is what `AgentTokenUsage.merging` is built for.
        if type == "message_start" {
            let message = root["message"] as? [String: Any]
            return anthropicUsage(message?["usage"]).map { [$0] } ?? []
        }
        if type == "message_delta" {
            return anthropicUsage(root["usage"]).map { [$0] } ?? []
        }

        if type == "content_block_start", let block = root["content_block"] as? [String: Any] {
            switch block["type"] as? String {
            case "thinking":
                state.thinkingBlocks[index] = AnthropicStreamState.ThinkingBlock(
                    text: block["thinking"] as? String ?? "",
                    signature: block["signature"] as? String ?? ""
                )
                return []
            case "redacted_thinking":
                return jsonValue(block).map { [.providerItem($0)] } ?? []
            case "tool_use":
                let id = block["id"] as? String ?? "index-\(index)"
                state.callIDs[index] = id
                return [.toolCallDelta(
                    id: id,
                    name: (block["name"] as? String).map {
                        canonicalName($0, wireNames: wireNames)
                    }, arguments: ""
                )]
            case "server_tool_use":
                // The provider's own call, not the model's. Claiming the index
                // here is the whole point: `server_tool_use` streams
                // `input_json_delta` exactly like `tool_use` does, and letting
                // those deltas fall through to the tool-call branch below
                // manufactures a call with an empty name — which `AgentRuntime`
                // rejects with `invalidToolCall`, failing the entire turn.
                state.serverBlocks[index] = AnthropicStreamState.ServerBlock(
                    id: block["id"] as? String ?? "", name: block["name"] as? String ?? ""
                )
                return []
            case "web_search_tool_result":
                state.serverBlocks[index] = AnthropicStreamState.ServerBlock()
                // Anthropic sends the query and its hits as two sibling blocks.
                // The query was parked at the previous block's stop so one card
                // can carry both.
                let query = (block["tool_use_id"] as? String)
                    .flatMap { state.pendingQueries.removeValue(forKey: $0) }
                return [.webSearch(AgentWebSearchActivity(
                    query: query ?? "", sources: anthropicSources(block["content"])
                ))]
            default:
                return []
            }
        }

        if type == "content_block_delta", let delta = root["delta"] as? [String: Any] {
            if state.thinkingBlocks[index] != nil {
                if let thinking = delta["thinking"] as? String {
                    state.thinkingBlocks[index]?.text += thinking
                    return [.reasoningDelta(thinking)]
                }
                if let signature = delta["signature"] as? String {
                    state.thinkingBlocks[index]?.signature += signature
                }
                return []
            }
            if state.serverBlocks[index] != nil {
                if let json = delta["partial_json"] as? String {
                    state.serverBlocks[index]?.input += json
                }
                return []
            }
            if let text = delta["text"] as? String { return [.textDelta(text)] }
            if let json = delta["partial_json"] as? String {
                return [.toolCallDelta(
                    id: state.callIDs[index] ?? "index-\(index)", name: nil, arguments: json
                )]
            }
        }

        if type == "content_block_stop",
            let block = state.thinkingBlocks.removeValue(forKey: index)
        {
            var item: [String: Any] = [
                "type": "thinking", "thinking": block.text,
            ]
            if !block.signature.isEmpty { item["signature"] = block.signature }
            return jsonValue(item).map { [.providerItem($0)] } ?? []
        }

        if type == "content_block_stop",
            let block = state.serverBlocks.removeValue(forKey: index), !block.id.isEmpty
        {
            state.pendingQueries[block.id] = anthropicQuery(block.input)
            return []
        }

        if type == "message_stop" { return [.finished(.completed)] }
        return []
    }

    /// A completed Responses search, as both a replay item and a card.
    ///
    /// Two events for one item, deliberately. The verbatim `web_search_call`
    /// has to go back to OpenAI on the next turn or the reasoning that produced
    /// it is orphaned, and that is what `providerItem` is for. The card wants
    /// the query, which lives at `action.query` and would mean nothing to the
    /// API. Neither can stand in for the other.
    ///
    /// Sources are absent here on purpose: Responses reports them as
    /// `url_citation` annotations on the message rather than on this item.
    private static func responsesWebSearch(_ item: [String: Any]) -> [AgentModelStreamEvent] {
        var events: [AgentModelStreamEvent] = []
        if let value = jsonValue(item) { events.append(.providerItem(value)) }
        let action = item["action"] as? [String: Any]
        let query = action?["query"] as? String ?? item["query"] as? String ?? ""
        events.append(.webSearch(AgentWebSearchActivity(query: query)))
        return events
    }

    private static func anthropicQuery(_ rawInput: String) -> String {
        guard let data = rawInput.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        return object["query"] as? String ?? ""
    }

    /// Tolerates the error shape. A failed search replaces the array of hits
    /// with a single `web_search_tool_result_error` object, so the cast is what
    /// turns "the search failed" into an empty source list rather than a crash.
    private static func anthropicSources(_ content: Any?) -> [AgentWebSearchActivity.Source] {
        (content as? [[String: Any]] ?? []).compactMap { row in
            guard let url = row["url"] as? String, !url.isEmpty else { return nil }
            return AgentWebSearchActivity.Source(
                title: row["title"] as? String ?? "", url: url
            )
        }
    }

    static func parseGoogle(
        _ root: [String: Any], wireNames: [String: String] = [:]
    ) -> [AgentModelStreamEvent] {
        // Read before the `candidates` guard for the same reason as Chat
        // Completions: Gemini repeats `usageMetadata` on chunks that carry no
        // candidate at all, and those are frequently the last ones.
        var events: [AgentModelStreamEvent] = googleUsage(root).map { [$0] } ?? []
        guard let candidate = (root["candidates"] as? [[String: Any]])?.first else { return events }
        // Grounding hangs off the candidate, beside `content`, not inside
        // `parts` — and it is read before the guard below, because a chunk can
        // carry the metadata for a search without carrying any content.
        if let grounding = candidate["groundingMetadata"] as? [String: Any] {
            events.append(.webSearch(googleGrounding(grounding)))
        }
        guard let content = candidate["content"] as? [String: Any] else {
            if candidate["finishReason"] != nil { events.append(.finished(.completed)) }
            return events
        }
        for part in content["parts"] as? [[String: Any]] ?? [] {
            if part["thought"] as? Bool == true {
                if let text = part["text"] as? String, !text.isEmpty {
                    events.append(.reasoningDelta(text))
                }
                if part["thoughtSignature"] != nil, let value = jsonValue(part) {
                    events.append(.providerItem(value))
                }
                continue
            }
            if let text = part["text"] as? String { events.append(.textDelta(text)) }
            if let call = part["functionCall"] as? [String: Any], let name = call["name"] as? String {
                let args = call["args"].flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data("{}".utf8)
                events.append(.toolCallSnapshot(
                    id: UUID().uuidString,
                    providerItemID: part["thoughtSignature"] as? String,
                    name: canonicalName(name, wireNames: wireNames),
                    arguments: String(decoding: args, as: UTF8.self)
                ))
            }
        }
        if candidate["finishReason"] != nil { events.append(.finished(events.containsToolCall ? .toolCalls : .completed)) }
        return events
    }

    /// Gemini reports every query of the turn in one `webSearchQueries` array
    /// and its sources in `groundingChunks`, with no mapping between them. The
    /// queries are joined rather than split into a card each, because inventing
    /// a source-to-query assignment the payload does not state would be worse
    /// than showing them together.
    private static func googleGrounding(
        _ metadata: [String: Any]
    ) -> AgentWebSearchActivity {
        let queries = (metadata["webSearchQueries"] as? [String] ?? [])
            .filter { !$0.isEmpty }
        let sources = (metadata["groundingChunks"] as? [[String: Any]] ?? []).compactMap {
            chunk -> AgentWebSearchActivity.Source? in
            guard let web = chunk["web"] as? [String: Any],
                let url = web["uri"] as? String, !url.isEmpty
            else { return nil }
            return AgentWebSearchActivity.Source(
                title: web["title"] as? String ?? "", url: url
            )
        }
        return AgentWebSearchActivity(
            query: queries.joined(separator: ", "), sources: sources
        )
    }

    // MARK: - Usage

    /// Four spellings of one fact, and one of them means something different.
    ///
    /// OpenAI, Responses and Gemini all report a prompt total that *includes*
    /// whatever was served from cache, so their cached figure is a subset to be
    /// shown, not added. Anthropic reports the three parts side by side and its
    /// `input_tokens` is only the *uncached* remainder — so with prompt caching
    /// working well it can be a few hundred against a hundred-thousand-token
    /// conversation. Taking it at face value, as the other three can be taken,
    /// would make the context gauge read near-empty exactly when the context is
    /// nearly full.
    private static func responsesUsage(_ response: [String: Any]) -> AgentModelStreamEvent? {
        guard let usage = response["usage"] as? [String: Any] else { return nil }
        let details = usage["input_tokens_details"] as? [String: Any]
        return .usage(AgentTokenUsage(
            inputTokens: count(usage["input_tokens"]),
            outputTokens: count(usage["output_tokens"]),
            cachedInputTokens: count(details?["cached_tokens"])
        ))
    }

    private static func chatUsage(_ root: [String: Any]) -> AgentModelStreamEvent? {
        guard let usage = root["usage"] as? [String: Any] else { return nil }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        return .usage(AgentTokenUsage(
            inputTokens: count(usage["prompt_tokens"]),
            outputTokens: count(usage["completion_tokens"]),
            cachedInputTokens: count(details?["cached_tokens"])
        ))
    }

    private static func anthropicUsage(_ usage: Any?) -> AgentModelStreamEvent? {
        guard let usage = usage as? [String: Any] else { return nil }
        let read = count(usage["cache_read_input_tokens"])
        return .usage(AgentTokenUsage(
            inputTokens: count(usage["input_tokens"]) + read
                + count(usage["cache_creation_input_tokens"]),
            outputTokens: count(usage["output_tokens"]),
            cachedInputTokens: read
        ))
    }

    private static func googleUsage(_ root: [String: Any]) -> AgentModelStreamEvent? {
        guard let usage = root["usageMetadata"] as? [String: Any] else { return nil }
        return .usage(AgentTokenUsage(
            inputTokens: count(usage["promptTokenCount"]),
            outputTokens: count(usage["candidatesTokenCount"]),
            cachedInputTokens: count(usage["cachedContentTokenCount"])
        ))
    }

    /// `JSONSerialization` hands back `NSNumber` for every JSON number, and a
    /// gateway is free to send `1024.0`. Reading these as `Int` directly works
    /// often enough to look correct and then silently returns nil.
    private static func count(_ value: Any?) -> Int {
        (value as? NSNumber)?.intValue ?? 0
    }
}

extension AgentProviderClient: AgentModelCompleting {}

/// Per-stream Anthropic block bookkeeping.
///
/// Anthropic streams two kinds of block through the same delta events: the
/// model's own `tool_use`, which Termind must execute, and the provider's
/// `server_tool_use`, which it must not. Knowing which index is which is the
/// only way to tell them apart mid-stream, and getting it wrong is not a
/// cosmetic error — see `parseAnthropic`.
nonisolated struct AnthropicStreamState: Sendable {
    fileprivate struct ThinkingBlock: Sendable {
        var text = ""
        var signature = ""
    }

    fileprivate struct ServerBlock: Sendable {
        var id: String = ""
        var name: String = ""
        var input: String = ""
    }

    fileprivate var callIDs: [Int: String] = [:]
    fileprivate var thinkingBlocks: [Int: ThinkingBlock] = [:]
    fileprivate var serverBlocks: [Int: ServerBlock] = [:]
    /// `server_tool_use.id` → query, held from that block's stop until the
    /// sibling `web_search_tool_result` arrives, so one card carries both.
    fileprivate var pendingQueries: [String: String] = [:]

    init() {}
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

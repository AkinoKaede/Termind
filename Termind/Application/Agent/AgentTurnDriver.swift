import Foundation

/// One assistant turn: stream the model's response, publish it as it arrives,
/// and hand back a finished message with its tool calls assembled.
///
/// Split out of the loop so the two hardest parts of a turn — reconciling four
/// providers' streaming shapes, and turning partial argument text into a
/// validated call — can be exercised without a runtime, a repository, or an
/// approval gate around them.
nonisolated struct AgentTurnDriver: Sendable {
    /// What one turn produced.
    ///
    /// A named type rather than the tuple this used to return: `usage` is the
    /// third member, and a three-member tuple destructured at the call site
    /// stops saying which is which.
    nonisolated struct Turn: Sendable {
        var message: AgentTranscriptMessage
        var reason: AgentStopReason
        /// Empty when the provider reported nothing — a gateway that strips
        /// usage, or a scripted model in a test. Callers must not treat that as
        /// a turn that cost zero.
        var usage: AgentTokenUsage = AgentTokenUsage()
    }

    private struct PendingToolCall {
        var name = ""
        var arguments = ""
        var providerItemID: String?
    }

    let model: any AgentModelStreaming
    let tools: AgentToolRegistry
    let channel: AgentEventChannel
    let runID: UUID

    func run(
        _ context: AgentModelContext
    ) async throws -> Turn {
        var message = AgentTranscriptMessage(role: .assistant)
        var pending: [String: PendingToolCall] = [:]
        var order: [String] = []
        var stopReason = AgentStopReason.completed
        var usage = AgentTokenUsage()
        // One card per distinct query. Gemini reports its grounding metadata on
        // more than one chunk of the same stream, and a card per chunk would
        // read as the model having searched four times for one thing.
        var recordedSearches: Set<String> = []
        channel.emit(.messageStarted(message))
        let messageID = message.id

        let reasoningEmitter = BalancedEmitter(
            configuration: .init(duration: .seconds(1), frequency: 30)
        ) { [channel] text in
            channel.emit(.reasoningDelta(messageID: messageID, text: text))
        }
        let textEmitter = BalancedEmitter(
            configuration: .init(duration: .milliseconds(500), frequency: 20)
        ) { [channel] text in
            channel.emit(.messageDelta(messageID: messageID, text: text))
        }
        var streamedCharacterCount = 0

        let request = AgentModelRequest(
            systemPrompt: context.systemPrompt,
            messages: context.messages,
            tools: context.tools
        )
        do {
            for try await event in model.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let text):
                    message.text += text
                    try await reasoningEmitter.wait()
                    if streamedCharacterCount >= 5_000 {
                        await textEmitter.update(.init(duration: .seconds(1), frequency: 3))
                    } else if streamedCharacterCount >= 2_000 {
                        await textEmitter.update(.init(duration: .seconds(1), frequency: 9))
                    } else if streamedCharacterCount >= 1_000 {
                        await textEmitter.update(
                            .init(duration: .milliseconds(500), frequency: 15)
                        )
                    }
                    await textEmitter.add(text)
                    streamedCharacterCount += text.count
                case .textSnapshot(let text):
                    // The UI is reconciled by messageFinished after the provider
                    // stream closes, so replacing here cannot duplicate deltas.
                    message.text = text
                case .reasoningDelta(let text):
                    if message.reasoning.isEmpty {
                        message.reasoning.append(AgentReasoningBlock(
                            text: text, createdAt: message.createdAt
                        ))
                    } else {
                        message.reasoning[
                            message.reasoning.index(before: message.reasoning.endIndex)
                        ].text += text
                    }
                    try await textEmitter.wait()
                    await reasoningEmitter.add(text)
                case .reasoningSnapshot(let text):
                    if message.reasoning.isEmpty {
                        message.reasoning.append(AgentReasoningBlock(
                            text: text, createdAt: message.createdAt
                        ))
                    } else {
                        message.reasoning[
                            message.reasoning.index(before: message.reasoning.endIndex)
                        ].text = text
                    }
                case .toolCallDelta(let id, let name, let arguments):
                    try await reasoningEmitter.wait()
                    try await textEmitter.wait()
                    if pending[id] == nil { order.append(id) }
                    var entry = pending[id] ?? PendingToolCall()
                    if let name { entry.name = name }
                    entry.arguments += arguments
                    pending[id] = entry
                case .toolCallSnapshot(let id, let providerItemID, let name, let arguments):
                    try await reasoningEmitter.wait()
                    try await textEmitter.wait()
                    if pending[id] == nil { order.append(id) }
                    pending[id] = PendingToolCall(
                        name: name, arguments: arguments,
                        providerItemID: providerItemID
                    )
                case .providerItem(let item):
                    if let id = item.objectValue?["id"]?.stringValue,
                        let index = message.providerItems.firstIndex(where: {
                            $0.objectValue?["id"]?.stringValue == id
                        })
                    {
                        // `response.completed` can carry a richer final reasoning
                        // item (notably encrypted_content) than output_item.done.
                        message.providerItems[index] = item
                    } else {
                        message.providerItems.append(item)
                    }
                case .webSearch(let activity):
                    try await reasoningEmitter.wait()
                    try await textEmitter.wait()
                    if recordedSearches.insert(activity.query).inserted {
                        recordNativeWebSearch(activity, sourceMessageID: message.id)
                    }
                case .usage(let reported):
                    usage = usage.merging(reported)
                case .finished(let reason):
                    stopReason = reason
                }
            }
            try await reasoningEmitter.wait()
            try await textEmitter.wait()
        } catch {
            if Task.isCancelled {
                await reasoningEmitter.cancel()
                await textEmitter.cancel()
            } else {
                try? await reasoningEmitter.wait()
                try? await textEmitter.wait()
            }
            throw error
        }
        message.toolCalls = try order.map { try assembled($0, pending: pending) }
        return Turn(message: message, reason: stopReason, usage: usage)
    }

    private func assembled(
        _ id: String, pending: [String: PendingToolCall]
    ) throws -> AgentToolCall {
        guard let call = pending[id], !call.name.isEmpty else {
            throw AgentRuntimeError.invalidToolCall
        }
        // A zero-parameter tool has exactly one valid argument value. Do not let
        // an OpenAI-compatible gateway's empty/null/duplicated serialization
        // turn `list_hosts` into a JSON decoding failure.
        if let schema = tools[call.name]?.descriptor.inputSchema.objectValue,
            schema["properties"]?.objectValue?.isEmpty == true,
            schema["additionalProperties"]?.boolValue == false
        {
            return AgentToolCall(
                id: id, name: call.name, arguments: .object([:]),
                providerItemID: call.providerItemID
            )
        }
        // Several OpenAI-compatible gateways stream an empty argument string for
        // a no-parameter function instead of the canonical `{}`.
        let arguments = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = (arguments.isEmpty ? "{}" : arguments).data(using: .utf8) else {
            throw AgentRuntimeError.invalidToolCall
        }
        do {
            return AgentToolCall(
                id: id, name: call.name,
                arguments: try AgentJSONValue.decode(data),
                providerItemID: call.providerItemID
            )
        } catch {
            throw AgentRuntimeError.invalidToolArguments(tool: call.name)
        }
    }

    /// Raises an ordinary tool card for a search the provider already ran.
    ///
    /// Proposed and finished in one breath, with no approval between, because
    /// by the time this event exists there is nothing left to authorize — the
    /// search happened on the provider's servers during the turn. The card is a
    /// record rather than a gate, which is the honest thing to show and better
    /// than an answer that cites pages the transcript never mentions reaching.
    ///
    /// The result content deliberately carries no `<untrusted-data>` wrapper.
    /// That wrapper is addressed to a model, and this content is never sent to
    /// one: it exists only for the card and for run history.
    private func recordNativeWebSearch(
        _ activity: AgentWebSearchActivity, sourceMessageID: UUID
    ) {
        let invocation = AgentToolInvocation(
            runID: runID,
            call: AgentToolCall(
                id: "provider-web-search-\(UUID().uuidString)",
                name: "web_search",
                arguments: .object(["query": .string(activity.query)])
            ),
            sourceMessageID: sourceMessageID
        )
        let descriptor = AgentToolDescriptor(
            name: "web_search",
            summary: String(localized: "Web search run by the model provider."),
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object(["query": .object(["type": .string("string")])]),
                "required": .array([.string("query")]),
                "additionalProperties": .bool(false),
            ]),
            target: .network,
            safety: .locallyReadOnly,
            concurrency: .parallel,
            presentation: .init(
                symbol: "magnifyingglass",
                activity: .semanticArgument(key: "query", fallback: .web), output: .json,
                detailPresenterID: "builtin.web_search",
                actionKind: .search
            )
        )
        let sources = AgentJSONValue.array(activity.sources.map { source in
            .object(["title": .string(source.title), "url": .string(source.url)])
        })
        var result = AgentToolResult(
            callID: invocation.call.id,
            content: sources.encodedString,
            // The flag every reader of this event needs: `callID` here names
            // nothing the provider ever asked for, so anything that replays tool
            // results must leave this one out. See
            // `AgentToolResult.isProviderNative`.
            metadata: [AgentToolResult.providerNativeKey: .bool(true)]
        )
        // Native searches bypass AgentToolExecutor, whose normal finish path
        // persists presentation metadata. Store it here as well so a restored
        // card can still derive its activity from `query` instead of exposing
        // the internal `web_search` protocol name.
        result.toolPresentation = descriptor.presentation
        channel.emit(.toolProposed(invocation, descriptor))
        channel.emit(.toolFinished(invocation, result))
    }
}

import Foundation

nonisolated struct AgentModelRequest: Sendable {
    var systemPrompt: String
    var messages: [AgentTranscriptMessage]
    var tools: [AgentToolDescriptor]
}

nonisolated enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    /// Authoritative complete text used by buffered/final provider responses.
    case textSnapshot(String)
    case toolCallDelta(id: String, name: String?, arguments: String)
    /// The authoritative completed tool call. Arguments replace, rather than
    /// append to, the partial streaming buffer.
    case toolCallSnapshot(
        id: String, providerItemID: String?, name: String, arguments: String
    )
    case providerItem(AgentJSONValue)
    /// A search the provider ran itself. Distinct from `providerItem`, which is
    /// the *replay* channel and must stay byte-shaped the way its provider
    /// sent it; this one is normalized for display and is never sent back.
    case webSearch(AgentWebSearchActivity)
    case finished(AgentStopReason)
}

/// The provider boundary — Pi's `streamFn`. Everything above it works in
/// `AgentTranscriptMessage`; everything below it speaks one vendor's wire
/// format. Swapping providers, proxying through a server, or scripting a run in
/// a test are all the same substitution.
nonisolated protocol AgentModelStreaming: Sendable {
    func stream(_ request: AgentModelRequest) -> AsyncThrowingStream<AgentModelStreamEvent, any Error>
}

/// A single buffered model response. Short, tool-free features use this path so
/// their success does not depend on SSE framing or a provider-specific [DONE]
/// event.
nonisolated protocol AgentModelCompleting: Sendable {
    func complete(_ request: AgentModelRequest) async throws -> [AgentModelStreamEvent]
}

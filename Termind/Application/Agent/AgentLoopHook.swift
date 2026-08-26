import Foundation

/// A tool call, as it looks to a hook deciding whether it should happen.
nonisolated struct AgentToolCallContext: Sendable {
    var invocation: AgentToolInvocation
    /// The descriptor *after* preflight, so a hook sees the same safety the
    /// approval gate is about to see rather than the tool's declared default.
    var descriptor: AgentToolDescriptor
    var userIntent: String
    var permissionMode: ChatPermissionMode
}

nonisolated enum AgentToolCallDecision: Hashable, Sendable {
    case proceed
    /// Turns into an error tool result carrying `reason`. The model is told, so
    /// a blocked call is something it can react to rather than a silence.
    case block(reason: String)
}

nonisolated struct AgentToolResultContext: Sendable {
    var invocation: AgentToolInvocation
    var descriptor: AgentToolDescriptor
    var result: AgentToolResult
}

/// A field-by-field replacement of what a tool returned. `nil` leaves a field
/// alone; there is deliberately no deep merge, so a hook that rewrites metadata
/// states the whole dictionary it wants and nothing survives by accident.
nonisolated struct AgentToolResultOverride: Sendable {
    var content: String?
    var isError: Bool?
    var metadata: [String: AgentJSONValue]?

    init(
        content: String? = nil,
        isError: Bool? = nil,
        metadata: [String: AgentJSONValue]? = nil
    ) {
        self.content = content
        self.isError = isError
        self.metadata = metadata
    }

    func applied(to result: AgentToolResult) -> AgentToolResult {
        var updated = result
        if let content { updated.content = content }
        if let isError { updated.isError = isError }
        if let metadata { updated.metadata = metadata }
        return updated
    }
}

nonisolated struct AgentTurnSummary: Sendable {
    var index: Int
    var message: AgentTranscriptMessage
    var results: [AgentToolResult]
}

/// An observer that may also intervene, around the points a run passes through.
///
/// Hooks are additive. **Authorization is not one of them**: `AgentApprovalHandling`
/// stays a structural stage of `AgentToolExecutor` that no configuration can
/// remove, and hooks run on either side of it. A permission gate that could be
/// dropped by leaving an element out of an array is not a gate.
///
/// Ordering within one call: `willExecute` → approval → the tool →
/// `didExecute`. A hook that blocks stops the call before it is authorized, so
/// blocking is never a way to *reach* something.
nonisolated protocol AgentLoopHook: Sendable {
    func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision
    func didExecute(_ context: AgentToolResultContext) async -> AgentToolResultOverride?
    func shouldStop(after summary: AgentTurnSummary) async -> Bool
}

/// No-op defaults, so a hook implements only the point it cares about.
///
/// `AgentRunPersisting` carries a comment refusing default implementations for
/// the opposite reason, and the difference is worth naming: there, a default
/// that silently satisfies a requirement drops run history with no diagnostic.
/// Here, doing nothing *is* the correct behaviour of an uninterested hook, and
/// the alternative is every conformer writing three stubs.
nonisolated extension AgentLoopHook {
    func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision { .proceed }
    func didExecute(_ context: AgentToolResultContext) async -> AgentToolResultOverride? { nil }
    func shouldStop(after summary: AgentTurnSummary) async -> Bool { false }
}

/// Runs a list of hooks as though it were one.
nonisolated struct AgentLoopHooks: Sendable {
    var hooks: [any AgentLoopHook]

    init(_ hooks: [any AgentLoopHook] = []) {
        self.hooks = hooks
    }

    var isEmpty: Bool { hooks.isEmpty }

    /// First refusal wins, and the hooks after it are not consulted — a call
    /// that is already not happening has nothing left to decide.
    func willExecute(_ context: AgentToolCallContext) async -> AgentToolCallDecision {
        for hook in hooks {
            if case .block(let reason) = await hook.willExecute(context) {
                return .block(reason: reason)
            }
        }
        return .proceed
    }

    /// Applied in order, each hook seeing what the previous one produced.
    func didExecute(
        _ invocation: AgentToolInvocation,
        descriptor: AgentToolDescriptor,
        result: AgentToolResult
    ) async -> AgentToolResult {
        var current = result
        for hook in hooks {
            let override = await hook.didExecute(AgentToolResultContext(
                invocation: invocation, descriptor: descriptor, result: current
            ))
            guard let override else { continue }
            current = override.applied(to: current)
        }
        return current
    }

    /// Any hook asking to stop stops the run — after the turn completes, not by
    /// abandoning it, so the transcript stays consistent and in-flight work is
    /// never orphaned.
    func shouldStop(after summary: AgentTurnSummary) async -> Bool {
        for hook in hooks where await hook.shouldStop(after: summary) { return true }
        return false
    }
}

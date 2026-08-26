import Foundation

nonisolated struct AgentToolExecutionContext: Sendable {
    var runID: UUID
    var userIntent: String
    var secretBroker: SecretBroker
    var userInteraction: any AgentUserInteractionHandling
    var preflightMetadata: [String: AgentJSONValue]
    var authorize: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
    /// What the call has produced so far.
    ///
    /// Pi's `onUpdate`, which it passes as a fourth argument to `execute`
    /// because it has no per-call context object to put it in. This is
    /// addressed to the reader and not to the model: the transcript gets the
    /// value the tool finally returns, never a partial one, so a tool may
    /// report as often as it likes without inflating anything the model pays
    /// for. Defaults to discarding, so a caller assembling a context by hand —
    /// a test, a preview — need not care.
    var report: @Sendable (AgentToolResult) -> Void = { _ in }
    /// Tell the model something after this call has already returned.
    ///
    /// For work a tool handed on rather than finished. Unlike `report`, this is
    /// not scoped to the call — that is the whole point of it — and unlike a
    /// result, it is never shown to the user. Dropped when there is no run left
    /// to tell, which is the honest outcome: a command finishing after its
    /// conversation went quiet has nobody to report to.
    var notify: @Sendable (String) -> Void = { _ in }
}

nonisolated protocol AgentTool: Sendable {
    var descriptor: AgentToolDescriptor { get }
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight
    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult
}

nonisolated extension AgentTool {
    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
    }
}

nonisolated struct AnyAgentTool: AgentTool, Sendable {
    let descriptor: AgentToolDescriptor
    private let executeClosure:
        @Sendable (AgentToolInvocation, AgentToolExecutionContext) async throws -> AgentToolResult
    private let preflightClosure: @Sendable (AgentToolInvocation) async throws -> AgentToolPreflight

    init<T: AgentTool>(_ tool: T) {
        descriptor = tool.descriptor
        preflightClosure = tool.preflight
        executeClosure = tool.execute
    }

    init(
        descriptor: AgentToolDescriptor,
        preflight: (@Sendable (AgentToolInvocation) async throws -> AgentToolPreflight)? = nil,
        execute: @escaping @Sendable (
            AgentToolInvocation, AgentToolExecutionContext
        ) async throws -> AgentToolResult
    ) {
        self.descriptor = descriptor
        preflightClosure = preflight ?? { invocation in
            AgentToolPreflight(invocation: invocation, safety: descriptor.safety)
        }
        executeClosure = execute
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        try await preflightClosure(invocation)
    }

    func execute(
        _ invocation: AgentToolInvocation,
        context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        try await executeClosure(invocation, context)
    }
}

import Foundation

nonisolated struct AgentToolExecutionContext: Sendable {
    var runID: UUID
    var userIntent: String
    var secretBroker: SecretBroker
    var userInteraction: any AgentUserInteractionHandling
    var preflightMetadata: [String: AgentJSONValue]
    var authorize: @Sendable (AgentApprovalRequest) async -> AgentApprovalDecision
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

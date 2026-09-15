import AgentKit
import Foundation
import TermindDomain

/// Planning registration for the ordinary `ssh_exec` identity. Destructive
/// commands never reach approval or execution in this posture.
public nonisolated struct PlanningSSHExecTool: AgentToolDefinition {
    public static let presenter = SSHExecTool.presenter
    private let base: SSHExecTool

    public init(
        authentication: AgentSSHAuthenticationRegistry,
        pool: AgentConnectionPool,
        background: AgentBackgroundCommands
    ) {
        base = SSHExecTool(authentication: authentication, pool: pool, background: background)
    }

    public var descriptor: AgentToolDescriptor { base.descriptor }

    public func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        let command = try Arguments(invocation).string("command")
        guard CommandRiskClassifier.assess(command).risk == .destructive else {
            return try await base.preflight(invocation)
        }
        return AgentToolPreflight(
            invocation: invocation, approvalPolicy: .deny,
            reasons: ["Planning cannot execute a destructive SSH command."]
        )
    }

    public func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        try await base.execute(invocation, context: context)
    }
}

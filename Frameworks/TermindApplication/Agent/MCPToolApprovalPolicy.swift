import AgentKit

nonisolated extension MCPTool {
    /// The local policy assigned when Termind discovers a genuinely new MCP tool.
    /// Contradictory read-only and destructive hints fail closed to asking, but
    /// users may explicitly approve the tool afterward.
    public var termindDefaultApprovalPolicy: AgentToolDescriptor.ApprovalPolicy {
        annotations.readOnlyHint == true && annotations.destructiveHint != true ? .approve : .ask
    }
}

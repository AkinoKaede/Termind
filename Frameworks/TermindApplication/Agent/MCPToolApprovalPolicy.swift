import AgentKit

nonisolated extension MCPTool {
    public var allowsTermindPreapproval: Bool {
        annotations.destructiveHint != true
    }

    /// Termind never treats a remotely flagged destructive tool as pre-approved.
    /// The hint cannot authorize anything, but it may tighten a local choice.
    public var termindApprovalPolicy: AgentToolDescriptor.ApprovalPolicy {
        !allowsTermindPreapproval && accessPolicy == .approve ? .ask : accessPolicy
    }

    public mutating func enforceTermindApprovalPolicy() {
        accessPolicy = termindApprovalPolicy
    }
}

nonisolated extension MCPServer {
    public func enforcingTermindApprovalPolicies() -> MCPServer {
        var server = self
        server.tools = tools.map { tool in
            var tool = tool
            tool.enforceTermindApprovalPolicy()
            return tool
        }
        return server
    }
}

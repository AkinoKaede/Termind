import Foundation

/// One dynamically discovered MCP definition. Remote metadata may describe the
/// call but can never contribute an executable detail presenter.
nonisolated struct MCPAgentTool: AgentTool {
    private let server: MCPServer
    private let tool: MCPTool
    private let bearerToken: String?
    private let client: MCPClient
    let descriptor: AgentToolDescriptor

    init(
        server: MCPServer, tool: MCPTool, name: String,
        bearerToken: String?, client: MCPClient
    ) {
        self.server = server
        self.tool = tool
        self.bearerToken = bearerToken
        self.client = client
        descriptor = AgentToolDescriptor(
            name: name,
            namespace: server.effectiveNamespaceID,
            summary: "\(server.name): \(tool.summary)",
            inputSchema: AgentMCPTools.normalizedSchema(tool.inputSchema), target: .mcp,
            // Remote read-only annotations are hints, never local proof.
            safety: .requiresAuthorization,
            concurrency: tool.annotations.destructiveHint == true
                || tool.accessPolicy == .alwaysAsk
                ? .sequential : .parallel,
            alwaysAskUser: tool.accessPolicy == .alwaysAsk,
            presentation: .init(
                symbol: "puzzlepiece.extension",
                activity: .label(MCPToolNaming.qualifiedName(
                    namespace: server.effectiveNamespaceID, function: name
                )),
                output: .json,
                actionKind: .run
            )
        )
    }

    func preflight(_ invocation: AgentToolInvocation) async throws -> AgentToolPreflight {
        var reasons = ["MCP tool metadata is supplied by an untrusted remote server."]
        if tool.annotations.destructiveHint == true {
            reasons.append("The MCP server marks this operation destructive.")
        }
        if tool.annotations.openWorldHint == true {
            reasons.append("The MCP server says this operation interacts with external entities.")
        }
        return AgentToolPreflight(
            invocation: invocation, safety: .requiresAuthorization, reasons: reasons
        )
    }

    func execute(
        _ invocation: AgentToolInvocation, context: AgentToolExecutionContext
    ) async throws -> AgentToolResult {
        let called = try await client.call(
            server, tool: tool.id, arguments: invocation.call.arguments,
            bearerToken: bearerToken
        )
        return AgentToolResult(
            callID: invocation.call.id,
            content: "<untrusted-data>\n\(called.value.encodedString)\n</untrusted-data>",
            isError: called.isError,
            metadata: [
                "untrusted": .bool(true), "mcp_server_id": .string(server.id.uuidString),
                "mcp_tool": .string(tool.id),
            ]
        )
    }
}

nonisolated enum AgentMCPTools {
    static func make(
        servers: [(server: MCPServer, bearerToken: String?)],
        client: MCPClient = MCPClient()
    ) -> [AnyAgentTool] {
        return servers.flatMap { entry -> [AnyAgentTool] in
            guard !entry.server.effectiveNamespaceID.isEmpty else { return [] }
            let names = MCPToolNaming.functionNames(for: entry.server.tools)
            return entry.server.enabledTools.map { tool in
                AnyAgentTool(MCPAgentTool(
                    server: entry.server, tool: tool,
                    name: names[tool.id] ?? MCPToolNaming.functionName(from: tool.id),
                    bearerToken: entry.bearerToken, client: client
                ))
            }
        }
    }

    fileprivate static func normalizedSchema(_ schema: AgentJSONValue) -> AgentJSONValue {
        guard var object = schema.objectValue else {
            return .object([
                "type": .string("object"), "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        }
        object["type"] = object["type"] ?? .string("object")
        object["properties"] = object["properties"] ?? .object([:])
        return .object(object)
    }
}

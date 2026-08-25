import Foundation

nonisolated enum AgentMCPTools {
    static func make(
        servers: [(server: MCPServer, bearerToken: String?)],
        client: MCPClient = MCPClient()
    ) -> [AnyAgentTool] {
        servers.flatMap { entry in
            entry.server.enabledTools.map { tool in
                make(server: entry.server, tool: tool, bearerToken: entry.bearerToken, client: client)
            }
        }
    }

    private static func make(
        server: MCPServer, tool: MCPTool, bearerToken: String?, client: MCPClient
    ) -> AnyAgentTool {
        let safeServer = server.id.uuidString.lowercased().prefix(8)
        let safeTool = tool.id.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        let descriptor = AgentToolDescriptor(
            name: "mcp__\(safeServer)__\(String(safeTool))",
            summary: "\(server.name): \(tool.summary)",
            inputSchema: normalizedSchema(tool.inputSchema), target: .mcp,
            // A server's readOnlyHint is not proof. Every MCP call stays inside
            // the action approval boundary unless Full access is selected.
            safety: .requiresAuthorization,
            alwaysAskUser: tool.requiresApproval
        )
        return AnyAgentTool(
            descriptor: descriptor,
            preflight: { invocation in
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
            },
            execute: { invocation, _ in
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
        )
    }

    private static func normalizedSchema(_ schema: AgentJSONValue) -> AgentJSONValue {
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

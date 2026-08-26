import Foundation

nonisolated enum AgentMCPTools {
    static func make(
        servers: [(server: MCPServer, bearerToken: String?)],
        client: MCPClient = MCPClient()
    ) -> [AnyAgentTool] {
        // Sanitizing is lossy — `list-hosts` and `list.hosts` both become
        // `list_hosts` — and two servers can share a UUID prefix. Names are
        // therefore disambiguated here, in a stable order, rather than left to
        // collide in whatever registry receives them.
        var taken = Set<String>()
        return servers.flatMap { entry in
            entry.server.enabledTools.map { tool in
                make(
                    server: entry.server, tool: tool,
                    name: unique(name(server: entry.server, tool: tool), taken: &taken),
                    bearerToken: entry.bearerToken, client: client
                )
            }
        }
    }

    private static func name(server: MCPServer, tool: MCPTool) -> String {
        let safeServer = server.id.uuidString.lowercased().prefix(8)
        let safeTool = tool.id.map { character in
            character.isLetter || character.isNumber || character == "_" ? character : "_"
        }
        return "mcp__\(safeServer)__\(String(safeTool))"
    }

    private static func unique(_ base: String, taken: inout Set<String>) -> String {
        var candidate = base
        var suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        taken.insert(candidate)
        return candidate
    }

    private static func make(
        server: MCPServer, tool: MCPTool, name: String,
        bearerToken: String?, client: MCPClient
    ) -> AnyAgentTool {
        let descriptor = AgentToolDescriptor(
            name: name,
            summary: "\(server.name): \(tool.summary)",
            inputSchema: normalizedSchema(tool.inputSchema), target: .mcp,
            // A server's readOnlyHint is not proof. Every MCP call stays inside
            // the action approval boundary unless Full access is selected.
            safety: .requiresAuthorization,
            // Parallel by default, following Pi, because an MCP call is a
            // network round trip and that is where concurrency pays. Note which
            // direction the remote metadata is allowed to push: a hint can only
            // make this *stricter*. Nothing a server asserts can grant
            // parallelism, so the rule that remote annotations are risk hints
            // rather than proof of safety still holds — and a tool the server
            // marks destructive, or wants asked about every time, takes its
            // whole turn serial.
            concurrency: tool.annotations.destructiveHint == true || tool.requiresApproval
                ? .sequential : .parallel,
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

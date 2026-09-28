import AgentKit
import Foundation

actor MCPServerProtocol {
    static let sessionHeader = "mcp-session-id"
    static let versionHeader = "mcp-protocol-version"
    static let maximumSessions = 64
    static let idleTimeout = Duration.seconds(30 * 60)
    static let supportedInitializationVersions = ["2025-11-25", "2025-06-18", "2024-11-05"]
    static let modernVersion = "2026-07-28"

    private let tools: MCPServerTools
    private var sessions: [String: MCPServerSession] = [:]
    private var sweeper: Task<Void, Never>?

    init(tools: MCPServerTools) {
        self.tools = tools
    }

    deinit { sweeper?.cancel() }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        await sweepIdle()
        let components = URLComponents(string: request.target)
        let path = components?.path ?? request.target
        switch (request.method, path) {
        case ("POST", "/mcp"):
            return await streamablePOST(request)
        case ("GET", "/mcp"):
            return HTTPResponse.text(
                405, "This server does not expose a standalone MCP SSE stream.", headers: ["Allow": "POST, DELETE"])
        case ("DELETE", "/mcp"):
            return await deleteSession(request)
        case ("GET", "/sse"):
            return legacySSE()
        case ("POST", "/messages"):
            let id = components?.queryItems?.first(where: { $0.name == "sessionId" })?.value
            return await legacyPOST(request, sessionID: id)
        default:
            return .text(404, "No MCP route exists at this path.")
        }
    }

    func stop() async {
        let removed = Array(sessions.values)
        sessions.removeAll()
        for session in removed {
            session.legacyContinuation?.finish()
            await tools.endSession(runID: session.runID, secretBroker: session.secretBroker)
        }
        sweeper?.cancel()
        sweeper = nil
    }

    func revokeModernOperations() async {
        let ids = sessions.filter { $0.value.isModern }.map(\.key)
        for id in ids { await removeSession(id) }
    }

    private func streamablePOST(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.header("content-type")?.lowercased().contains("application/json") == true else {
            return .text(415, "MCP requests must use application/json.")
        }
        let message: RPCMessage
        do { message = try RPCMessage(request.body) } catch {
            return Self.jsonResponse(.error(id: .null, code: -32700, message: "Parse error"), status: 400)
        }

        if message.method == "server/discover"
            || message.params?["_meta"]?.objectValue?["io.modelcontextprotocol/protocolVersion"] != nil
            || request.header(Self.versionHeader) == Self.modernVersion
        {
            return await modernPOST(request, message: message)
        }

        if message.method == "initialize" {
            guard sessions.count < Self.maximumSessions else {
                return .text(503, "Too many MCP sessions are active.")
            }
            let session = makeSession(message: message, legacy: false)
            sessions[session.id] = session
            let response = await dispatch(message, sessionID: session.id)
            return Self.jsonResponse(
                response
                    ?? .error(id: message.id ?? .null, code: -32603, message: "Initialize did not produce a response"),
                headers: ["Mcp-Session-Id": session.id]
            )
        }

        guard let sessionID = request.header(Self.sessionHeader) else {
            return .text(400, "Mcp-Session-Id is required after initialize.")
        }
        guard var session = sessions[sessionID], !session.isLegacy, !session.isModern else {
            return .text(404, "The MCP session is unknown or expired.")
        }
        guard let version = request.header(Self.versionHeader), version == session.protocolVersion else {
            return .text(400, "MCP-Protocol-Version must match the initialized session.")
        }
        session.lastUsedAt = .now
        sessions[sessionID] = session
        let response = await dispatch(message, sessionID: sessionID)
        guard let response else { return HTTPResponse(status: 202) }
        return Self.jsonResponse(response)
    }

    private func modernPOST(_ request: HTTPRequest, message: RPCMessage) async -> HTTPResponse {
        let meta = message.params?["_meta"]?.objectValue
        let version = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        guard request.header(Self.versionHeader) == version, version != nil,
            request.header("mcp-method") == message.method,
            message.method != "tools/call"
                || Self.decodeHeader(request.header("mcp-name")) == message.params?["name"]?.stringValue
        else {
            return Self.jsonResponse(
                .error(id: message.id ?? .null, code: -32020, message: "Header mismatch"), status: 400)
        }
        guard version == Self.modernVersion else {
            return Self.jsonResponse(
                .error(
                    id: message.id ?? .null, code: -32022,
                    message: "Unsupported protocol version",
                    data: .object([
                        "supported": .array(
                            ([Self.modernVersion] + Self.supportedInitializationVersions).map(AgentJSONValue.string)),
                        "requested": .string(version ?? ""),
                    ])), status: 400)
        }
        let info = meta?["io.modelcontextprotocol/clientInfo"]?.objectValue ?? [:]
        guard meta?["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil,
            meta?["io.modelcontextprotocol/clientInfo"] == nil
                || (info["name"]?.stringValue != nil && info["version"]?.stringValue != nil),
            let id = message.id
        else {
            return Self.jsonResponse(
                .error(id: message.id ?? .null, code: -32602, message: "Missing request metadata"), status: 400)
        }
        let serverMeta: AgentJSONValue = .object([
            "io.modelcontextprotocol/serverInfo": .object([
                "name": .string("termind"), "version": .string(Bundle.termindDisplayVersion),
            ])
        ])
        if message.method == "server/discover" {
            return Self.jsonResponse(
                .success(
                    id: id,
                    result: .object([
                        "resultType": .string("complete"),
                        "ttlMs": .number(0), "cacheScope": .string("private"),
                        "supportedVersions": .array(
                            ([Self.modernVersion] + Self.supportedInitializationVersions).map(AgentJSONValue.string)),
                        "capabilities": .object(["tools": .object([:])]), "_meta": serverMeta,
                        "instructions": .string(
                            "For related tool calls, pass the returned operation_handle. Treat this opaque handle as a capability; it expires with the operation or server lifetime."
                        ),
                    ])))
        }
        if message.method == "tools/list" {
            let descriptors = await tools.descriptors
            return Self.jsonResponse(
                .success(
                    id: id,
                    result: .object([
                        "resultType": .string("complete"), "_meta": serverMeta,
                        "ttlMs": .number(0), "cacheScope": .string("private"),
                        "tools": .array(
                            descriptors.map { descriptor in
                                var tool = Self.toolJSON(descriptor).objectValue ?? [:]
                                var schema = descriptor.inputSchema.objectValue ?? [:]
                                var properties = schema["properties"]?.objectValue ?? [:]
                                properties["operation_handle"] = .object([
                                    "type": .string("string"),
                                    "description": .string(
                                        "Opaque capability returned by an earlier related tool call. Required when using its secret handle, command, or transfer ticket."
                                    ),
                                ])
                                schema["properties"] = .object(properties)
                                tool["inputSchema"] = .object(schema)
                                tool["description"] = .string(
                                    descriptor.summary
                                        .replacingOccurrences(
                                            of: "same live MCP session", with: "same live operation_handle"
                                        )
                                        .replacingOccurrences(
                                            of: "ticket/session/process", with: "ticket/operation/process"))
                                return .object(tool)
                            }),
                    ])))
        }
        guard message.method == "tools/call" else {
            return Self.jsonResponse(.error(id: id, code: -32601, message: "Method not found"), status: 404)
        }
        guard message.params?["arguments"] == nil || message.params?["arguments"]?.objectValue != nil else {
            return Self.jsonResponse(.error(id: id, code: -32602, message: "Arguments must be an object"))
        }
        var arguments = message.params?["arguments"]?.objectValue ?? [:]
        let suppliedHandle = arguments.removeValue(forKey: "operation_handle")
        let operationID: String
        if let suppliedHandle {
            guard let handle = suppliedHandle.stringValue, sessions[handle]?.isModern == true else {
                return Self.jsonResponse(
                    .error(id: id, code: -32602, message: "Operation handle is unknown or expired"))
            }
            operationID = handle
        } else {
            guard sessions.count < Self.maximumSessions else { return .text(503, "Too many active operations") }
            operationID = UUID().uuidString + UUID().uuidString
            sessions[operationID] = MCPServerSession(
                id: operationID, runID: UUID(), secretBroker: SecretBroker(), protocolVersion: Self.modernVersion,
                clientName: info["name"]?.stringValue ?? "MCP client", isModern: true, initialized: true,
                isLegacy: false)
        }
        var call = message
        call.params?["arguments"] = .object(arguments)
        guard let response = await dispatch(call, sessionID: operationID) else { return HTTPResponse(status: 202) }
        let successful = response.value.objectValue?["result"]?.objectValue?["isError"] == .bool(false)
        let retainsState =
            suppliedHandle != nil
            || (successful
                && ["request_user_secret", "sftp_upload", "sftp_download"].contains(
                    message.params?["name"]?.stringValue ?? ""))
        if !retainsState { await removeSession(operationID) }
        var envelope = response.value.objectValue ?? [:]
        if var result = envelope["result"]?.objectValue {
            result["resultType"] = .string("complete")
            if retainsState {
                var structured = result["structuredContent"]?.objectValue ?? [:]
                structured["operation_handle"] = .string(operationID)
                result["structuredContent"] = .object(structured)
                var content = result["content"]?.arrayValue ?? []
                content.append(.object(["type": .string("text"), "text": .string("operation_handle: " + operationID)]))
                result["content"] = .array(content)
            }
            envelope["result"] = .object(result)
        }
        return Self.jsonResponse(RPCResponse(value: .object(envelope)))
    }

    private static func decodeHeader(_ value: String?) -> String? {
        guard let value, value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }),
            value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        if value.hasPrefix("=?base64?"), value.hasSuffix("?=") {
            guard let data = Data(base64Encoded: String(value.dropFirst(9).dropLast(2))) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        return value
    }

    private func deleteSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = request.header(Self.sessionHeader) else {
            return .text(400, "Mcp-Session-Id is required.")
        }
        guard let existing = sessions[id], !existing.isModern, let removed = sessions.removeValue(forKey: id) else {
            return .text(404, "The MCP session is unknown or expired.")
        }
        removed.legacyContinuation?.finish()
        await tools.endSession(runID: removed.runID, secretBroker: removed.secretBroker)
        return HTTPResponse(status: 200)
    }

    private func legacySSE() -> HTTPResponse {
        guard sessions.count < Self.maximumSessions else {
            return .text(503, "Too many MCP sessions are active.")
        }
        let id = UUID().uuidString
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSession(id) }
        }
        sessions[id] = MCPServerSession(
            id: id, runID: UUID(), secretBroker: SecretBroker(),
            protocolVersion: MCPClient.legacyVersion,
            clientName: "Legacy MCP client", isLegacy: true,
            legacyContinuation: continuation
        )
        continuation.yield(Self.sse(event: "endpoint", data: "/messages?sessionId=\(id)"))
        startSweeperIfNeeded()
        return HTTPResponse(
            status: 200,
            headers: [
                "Content-Type": "text/event-stream", "Cache-Control": "no-cache",
                "X-Accel-Buffering": "no",
            ],
            stream: stream
        )
    }

    private func legacyPOST(_ request: HTTPRequest, sessionID: String?) async -> HTTPResponse {
        guard request.header("content-type")?.lowercased().contains("application/json") == true else {
            return .text(415, "MCP requests must use application/json.")
        }
        guard let sessionID, var session = sessions[sessionID], session.isLegacy,
            let continuation = session.legacyContinuation
        else { return .text(404, "The legacy MCP session is unknown or expired.") }
        let message: RPCMessage
        do { message = try RPCMessage(request.body) } catch {
            continuation.yield(
                Self.sse(
                    event: "message",
                    data: RPCResponse.error(id: .null, code: -32700, message: "Parse error").data
                ))
            return HTTPResponse(status: 202)
        }
        if message.method == "initialize" {
            session.clientName = message.clientName ?? session.clientName
        }
        session.lastUsedAt = .now
        sessions[sessionID] = session
        if let response = await dispatch(message, sessionID: sessionID) {
            continuation.yield(Self.sse(event: "message", data: response.data))
        }
        return HTTPResponse(status: 202)
    }

    private func dispatch(_ message: RPCMessage, sessionID: String) async -> RPCResponse? {
        guard var session = sessions[sessionID] else {
            return .error(id: message.id ?? .null, code: -32001, message: "Session expired")
        }
        let isNotification = message.id == nil
        let response: RPCResponse?
        switch message.method {
        case "initialize":
            guard !session.initialized else {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32600,
                        message: "initialize may only be sent once"
                    )
                break
            }
            if let clientName = message.clientName { session.clientName = clientName }
            let requested = message.params?["protocolVersion"]?.stringValue
            session.protocolVersion =
                session.isLegacy
                ? MCPClient.legacyVersion
                : Self.negotiatedStreamableVersion(requested)
            response =
                isNotification
                ? nil
                : .success(
                    id: message.id ?? .null,
                    result: .object([
                        "protocolVersion": .string(session.protocolVersion),
                        "capabilities": .object(["tools": .object([:])]),
                        "serverInfo": .object([
                            "name": .string("termind"),
                            "title": .string("Termind MCP Server"),
                            "version": .string(Bundle.termindDisplayVersion),
                        ]),
                        "instructions": .string(
                            """
                            Use list_hosts to discover host_id values. Use ssh_exec to execute remote commands \
                            and SFTP tools for remote files; no open interactive terminal is required. Termind \
                            handles SSH and SFTP login using the host configuration and may show an authentication \
                            window on this Mac. request_user_secret is not required for SSH login or ordinary \
                            commands: call ssh_exec with host_id and command, omitting secret_handle and \
                            stdin_purpose. Only when a command actually needs secret standard input, call \
                            request_user_secret, then pass its secret_handle to ssh_exec with stdin_purpose \
                            exactly matching the original purpose. The presence of sudo alone does not mean a \
                            password is needed. Never put plaintext secrets in commands or ordinary chat. \
                            The handle is bound to this session, host, tool, and purpose, and can be used only once.
                            """
                        ),
                    ]))
        case "notifications/initialized":
            session.initialized = true
            response = nil
        case "ping":
            response = isNotification ? nil : .success(id: message.id ?? .null, result: .object([:]))
        case "tools/list":
            guard session.initialized else {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32002, message: "Server not initialized"
                    )
                break
            }
            let descriptors = await tools.descriptors
            response =
                isNotification
                ? nil
                : .success(
                    id: message.id ?? .null,
                    result: .object(["tools": .array(descriptors.map(Self.toolJSON))])
                )
        case "tools/call":
            guard session.initialized else {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32002, message: "Server not initialized"
                    )
                break
            }
            guard let params = message.params,
                let name = params["name"]?.stringValue
            else {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32602,
                        message: "tools/call requires an enabled tool name and object arguments"
                    )
                break
            }
            let arguments = params["arguments"] ?? .object([:])
            guard
                arguments.objectValue != nil,
                await tools.contains(name)
            else {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32602,
                        message: "tools/call requires an enabled tool name and object arguments"
                    )
                break
            }
            do {
                let result = try await tools.call(
                    name: name, arguments: arguments, runID: session.runID,
                    clientName: session.clientName,
                    callID: message.id?.encodedString ?? UUID().uuidString,
                    secretBroker: session.secretBroker
                )
                response =
                    isNotification
                    ? nil
                    : .success(
                        id: message.id ?? .null, result: Self.toolResultJSON(result)
                    )
            } catch {
                response =
                    isNotification
                    ? nil
                    : .error(
                        id: message.id ?? .null, code: -32602, message: error.localizedDescription
                    )
            }
        default:
            response =
                isNotification
                ? nil
                : .error(
                    id: message.id ?? .null, code: -32601,
                    message: "Method not found: \(message.method)"
                )
        }
        if sessions[sessionID] != nil {
            session.lastUsedAt = .now
            sessions[sessionID] = session
        } else {
            await tools.endSession(runID: session.runID, secretBroker: session.secretBroker)
        }
        startSweeperIfNeeded()
        return response
    }

    private func makeSession(message: RPCMessage, legacy: Bool) -> MCPServerSession {
        let id = UUID().uuidString
        return MCPServerSession(
            id: id, runID: UUID(), secretBroker: SecretBroker(),
            protocolVersion: legacy
                ? MCPClient.legacyVersion : "2025-11-25",
            clientName: message.clientName ?? "MCP client", isLegacy: legacy
        )
    }

    private func removeSession(_ id: String) async {
        guard let removed = sessions.removeValue(forKey: id) else { return }
        await tools.endSession(runID: removed.runID, secretBroker: removed.secretBroker)
    }

    private func startSweeperIfNeeded() {
        guard sweeper == nil, !sessions.isEmpty else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                guard let self else { return }
                await self.sweepIdle()
                if await self.sessions.isEmpty { return }
            }
        }
    }

    private func sweepIdle() async {
        let now = ContinuousClock.now
        let expired = sessions.filter { now - $0.value.lastUsedAt >= Self.idleTimeout }
        for (id, session) in expired {
            if await tools.hasTransferActivity(runID: session.runID) { continue }
            session.legacyContinuation?.finish()
            sessions[id] = nil
            await tools.endSession(runID: session.runID, secretBroker: session.secretBroker)
        }
        if sessions.isEmpty {
            sweeper?.cancel()
            sweeper = nil
        }
    }

    static func negotiatedStreamableVersion(_ requested: String?) -> String {
        guard let requested, supportedInitializationVersions.contains(requested) else {
            return "2025-11-25"
        }
        return requested
    }

    private static func toolJSON(_ descriptor: AgentToolDescriptor) -> AgentJSONValue {
        let readOnly = [
            "list_hosts", "get_metrics", "request_user_secret", "ssh_wait",
            "sftp_list", "sftp_stat", "sftp_read", "sftp_upload_status", "sftp_download", "sftp_download_status",
        ].contains(descriptor.name)
        let destructive = [
            "ssh_exec", "sftp_write", "sftp_move", "sftp_copy", "sftp_chmod", "sftp_delete", "sftp_upload",
        ]
        .contains(descriptor.name)
        let openWorld = ![
            "list_hosts", "ssh_wait", "request_user_secret", "sftp_upload_status", "sftp_download_status",
        ]
        .contains(descriptor.name)
        return .object([
            "name": .string(descriptor.name),
            "description": .string(descriptor.summary),
            "inputSchema": descriptor.inputSchema,
            "annotations": .object([
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(descriptor.name == "sftp_chmod"),
                "openWorldHint": .bool(openWorld),
            ]),
        ])
    }

    private static func toolResultJSON(_ result: AgentToolResult) -> AgentJSONValue {
        let text = result.untrustedPayload ?? result.content
        var value: [String: AgentJSONValue] = [
            "content": .array([
                .object([
                    "type": .string("text"), "text": .string(text),
                ])
            ]),
            "isError": .bool(result.isError),
        ]
        if let parsed = try? AgentJSONValue.decode(Data(text.utf8)) {
            value["structuredContent"] =
                parsed.objectValue == nil
                ? .object(["value": parsed]) : parsed
        }
        if result.isTruncated {
            value["_meta"] = .object(["termind/truncated": .bool(true)])
        }
        return .object(value)
    }

    private static func jsonResponse(
        _ response: RPCResponse, status: Int = 200, headers: [String: String] = [:]
    ) -> HTTPResponse {
        var all = headers
        all["Content-Type"] = "application/json"
        return HTTPResponse(status: status, headers: all, body: response.data)
    }

    private static func sse(event: String, data: String) -> Data {
        Data("event: \(event)\ndata: \(data)\n\n".utf8)
    }

    private static func sse(event: String, data: Data) -> Data {
        sse(event: event, data: String(decoding: data, as: UTF8.self))
    }
}

private nonisolated struct RPCMessage: Sendable {
    var id: AgentJSONValue?
    var method: String
    var params: [String: AgentJSONValue]?

    init(_ data: Data) throws {
        guard let object = try AgentJSONValue.decode(data).objectValue,
            object["jsonrpc"]?.stringValue == "2.0",
            let method = object["method"]?.stringValue
        else { throw RPCMessageError.invalid }
        id = object["id"]
        self.method = method
        params = object["params"]?.objectValue
    }

    var clientName: String? {
        let info = params?["clientInfo"]?.objectValue
        return info?["title"]?.stringValue ?? info?["name"]?.stringValue
    }
}

private nonisolated enum RPCMessageError: Error { case invalid }

private nonisolated struct RPCResponse: Sendable {
    var value: AgentJSONValue
    var data: Data { value.encodedData }

    static func success(id: AgentJSONValue, result: AgentJSONValue) -> Self {
        Self(value: .object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    static func error(id: AgentJSONValue, code: Int, message: String, data: AgentJSONValue = .null) -> Self {
        Self(
            value: .object([
                "jsonrpc": .string("2.0"), "id": id,
                "error": .object([
                    "code": .number(Double(code)), "message": .string(message), "data": data,
                ]),
            ]))
    }
}

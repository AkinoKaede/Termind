import AgentKit
import Foundation

actor MCPServerProtocol {
    static let sessionHeader = "mcp-session-id"
    static let versionHeader = "mcp-protocol-version"
    static let maximumSessions = 64
    static let idleTimeout = Duration.seconds(30 * 60)
    static let supportedStreamableVersions = [MCPClient.preferredVersion]

    typealias ClientCountHandler = @Sendable (Int) -> Void

    private let tools: MCPServerTools
    private var clientCountChanged: ClientCountHandler
    private var sessions: [String: MCPServerSession] = [:]
    private var sweeper: Task<Void, Never>?

    init(
        tools: MCPServerTools,
        clientCountChanged: @escaping ClientCountHandler = { _ in }
    ) {
        self.tools = tools
        self.clientCountChanged = clientCountChanged
    }

    func setClientCountHandler(_ handler: @escaping ClientCountHandler) {
        clientCountChanged = handler
        handler(sessions.count)
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
            return HTTPResponse.text(405, "This server does not expose a standalone MCP SSE stream.", headers: ["Allow": "POST, DELETE"])
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
        clientCountChanged(0)
    }

    private func streamablePOST(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.header("content-type")?.lowercased().contains("application/json") == true else {
            return .text(415, "MCP requests must use application/json.")
        }
        let message: RPCMessage
        do { message = try RPCMessage(request.body) }
        catch {
            return Self.jsonResponse(.error(id: .null, code: -32700, message: "Parse error"), status: 400)
        }

        if message.method == "initialize" {
            guard sessions.count < Self.maximumSessions else {
                return .text(503, "Too many MCP sessions are active.")
            }
            let session = makeSession(message: message, legacy: false)
            sessions[session.id] = session
            sessionCountDidChange()
            let response = await dispatch(message, sessionID: session.id)
            return Self.jsonResponse(
                response ?? .error(id: message.id ?? .null, code: -32603, message: "Initialize did not produce a response"),
                headers: ["Mcp-Session-Id": session.id]
            )
        }

        guard let sessionID = request.header(Self.sessionHeader) else {
            return .text(400, "Mcp-Session-Id is required after initialize.")
        }
        guard var session = sessions[sessionID], !session.isLegacy else {
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

    private func deleteSession(_ request: HTTPRequest) async -> HTTPResponse {
        guard let id = request.header(Self.sessionHeader) else {
            return .text(400, "Mcp-Session-Id is required.")
        }
        guard let removed = sessions.removeValue(forKey: id) else {
            return .text(404, "The MCP session is unknown or expired.")
        }
        removed.legacyContinuation?.finish()
        await tools.endSession(runID: removed.runID, secretBroker: removed.secretBroker)
        sessionCountDidChange()
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
        sessionCountDidChange()
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
        do { message = try RPCMessage(request.body) }
        catch {
            continuation.yield(Self.sse(
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
                response = isNotification ? nil : .error(
                    id: message.id ?? .null, code: -32600,
                    message: "initialize may only be sent once"
                )
                break
            }
            if let clientName = message.clientName { session.clientName = clientName }
            let requested = message.params?["protocolVersion"]?.stringValue
            session.protocolVersion = session.isLegacy
                ? MCPClient.legacyVersion
                : Self.negotiatedStreamableVersion(requested)
            response = isNotification ? nil : .success(id: message.id ?? .null, result: .object([
                "protocolVersion": .string(session.protocolVersion),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object([
                    "name": .string("termind"),
                    "title": .string("Termind MCP Server"),
                    "version": .string(Bundle.termindDisplayVersion),
                ]),
                "instructions": .string(
                    "Use list_hosts to discover host_id values. SSH and SFTP calls use Termind's saved Vault credentials and may show an authentication window on this Mac. For secret command input, call request_user_secret, then pass its secret_handle to ssh_exec with stdin_purpose exactly matching the original purpose. The handle is bound to this session, host, tool, and purpose, and can be used only once."
                ),
            ]))
        case "notifications/initialized":
            session.initialized = true
            response = nil
        case "ping":
            response = isNotification ? nil : .success(id: message.id ?? .null, result: .object([:]))
        case "tools/list":
            guard session.initialized else {
                response = isNotification ? nil : .error(
                    id: message.id ?? .null, code: -32002, message: "Server not initialized"
                )
                break
            }
            let descriptors = await tools.descriptors
            response = isNotification ? nil : .success(
                id: message.id ?? .null,
                result: .object(["tools": .array(descriptors.map(Self.toolJSON))])
            )
        case "tools/call":
            guard session.initialized else {
                response = isNotification ? nil : .error(
                    id: message.id ?? .null, code: -32002, message: "Server not initialized"
                )
                break
            }
            guard let params = message.params,
                let name = params["name"]?.stringValue
            else {
                response = isNotification ? nil : .error(
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
                response = isNotification ? nil : .error(
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
                response = isNotification ? nil : .success(
                    id: message.id ?? .null, result: Self.toolResultJSON(result)
                )
            } catch {
                response = isNotification ? nil : .error(
                    id: message.id ?? .null, code: -32602, message: error.localizedDescription
                )
            }
        default:
            response = isNotification ? nil : .error(
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
            id: id, runID: UUID(), secretBroker: SecretBroker(), protocolVersion: legacy
                ? MCPClient.legacyVersion : MCPClient.preferredVersion,
            clientName: message.clientName ?? "MCP client", isLegacy: legacy
        )
    }

    private func removeSession(_ id: String) async {
        guard let removed = sessions.removeValue(forKey: id) else { return }
        await tools.endSession(runID: removed.runID, secretBroker: removed.secretBroker)
        sessionCountDidChange()
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
            session.legacyContinuation?.finish()
            sessions[id] = nil
            await tools.endSession(runID: session.runID, secretBroker: session.secretBroker)
        }
        if !expired.isEmpty { sessionCountDidChange() }
        if sessions.isEmpty {
            sweeper?.cancel()
            sweeper = nil
        }
    }

    private func sessionCountDidChange() { clientCountChanged(sessions.count) }

    static func negotiatedStreamableVersion(_ requested: String?) -> String {
        guard let requested, supportedStreamableVersions.contains(requested) else {
            return MCPClient.preferredVersion
        }
        return requested
    }

    private static func toolJSON(_ descriptor: AgentToolDescriptor) -> AgentJSONValue {
        let readOnly = descriptor.safety.isAutoAllowed
        let destructive = ["ssh_exec", "sftp_write", "sftp_move", "sftp_chmod", "sftp_delete"]
            .contains(descriptor.name)
        let openWorld = !["list_hosts", "ssh_wait", "request_user_secret"]
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
            "content": .array([.object([
                "type": .string("text"), "text": .string(text),
            ])]),
            "isError": .bool(result.isError),
        ]
        if let parsed = try? AgentJSONValue.decode(Data(text.utf8)) {
            value["structuredContent"] = parsed.objectValue == nil
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

    static func error(id: AgentJSONValue, code: Int, message: String) -> Self {
        Self(value: .object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object([
                "code": .number(Double(code)), "message": .string(message),
            ]),
        ]))
    }
}

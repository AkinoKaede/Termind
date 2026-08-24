import Foundation

/// What one successful `Connect` learned about a server.
nonisolated struct MCPDiscovery: Sendable {
    var protocolVersion: String
    var serverName: String
    var tools: [MCPTool]
}

/// Connects to an MCP server and asks what tools it has.
///
/// Discovery only. This runs the handshake and `tools/list`, and stops there —
/// actually *calling* a tool belongs with the chat loop in P3, and it will go
/// through the same approval gate an AI-proposed command does. That gate is why
/// `MCPTool.requiresApproval` arrives from here already set.
///
/// Two transports, both HTTP. There is no stdio here because Termind is sandboxed
/// and cannot launch a local process — see `MCPServer`.
nonisolated struct MCPClient: Sendable {
    /// The version Termind asks for.
    ///
    /// Not the newest one. MCP `2026-07-28` dropped the `initialize` handshake
    /// and `Mcp-Session-Id` for a stateless per-request model a month ago;
    /// implementing that today would mean failing against the servers people
    /// actually run. `2025-06-18` is what is deployed, and the specification
    /// gives the transport below it a twelve-month offramp, so this has room.
    ///
    /// What comes back from `initialize` is used from then on regardless — a
    /// server that answers with a different version is answered in that version.
    static let preferredVersion = "2025-06-18"

    /// The version the legacy transport speaks.
    static let legacyVersion = "2024-11-05"

    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            // Longer than the catalog client's: this is a multi-step exchange,
            // and an SSE stream that pauses between our own requests must not
            // be mistaken for a dead one.
            configuration.timeoutIntervalForRequest = 30
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func discover(_ server: MCPServer, bearerToken: String?) async throws -> MCPDiscovery {
        let trimmed = server.url.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw MCPError.badURL(trimmed)
        }

        switch server.transport {
        case .streamableHTTP:
            return try await discoverStreamable(at: url, server: server, bearerToken: bearerToken)
        case .sse:
            return try await discoverSSE(at: url, server: server, bearerToken: bearerToken)
        }
    }

    // MARK: - Streamable HTTP

    /// POST `initialize` → POST `notifications/initialized` → POST `tools/list`.
    ///
    /// Each POST may be answered as `application/json` or as an SSE stream
    /// carrying the same response, and the specification requires clients to
    /// handle both — so `send` branches on the content type rather than
    /// assuming the shape a particular server happened to use last time.
    private func discoverStreamable(
        at url: URL, server: MCPServer, bearerToken: String?
    ) async throws -> MCPDiscovery {
        var context = RequestContext(
            url: url,
            version: Self.preferredVersion,
            sessionID: nil,
            server: server,
            bearerToken: bearerToken
        )

        let initialize: InitializeResult
        do {
            initialize = try await send(
                .initialize(version: Self.preferredVersion), id: 1, context: &context)
        } catch MCPError.http(let status) where (400..<500).contains(status) {
            // 404 and 405 are exactly what a server running only the older
            // transport answers a POST with. Said plainly rather than retried
            // silently, because the transport is a setting the user chose and
            // quietly overriding it would make that setting a lie.
            throw MCPError.wrongTransport(status: status)
        }

        // From here on, speak whatever the server agreed to.
        context.version = initialize.protocolVersion ?? Self.preferredVersion

        try await notify(.initialized, context: context)
        let tools = try await listTools(context: &context)
        await endSession(context)

        return MCPDiscovery(
            protocolVersion: context.version,
            serverName: initialize.serverInfo?.name ?? server.name,
            tools: tools
        )
    }

    /// One JSON-RPC request, and its response.
    ///
    /// Also the only place `Mcp-Session-Id` is read. A server that assigns one
    /// at initialization rejects every later request that omits it, so it is
    /// captured here rather than at the call sites that would each have to
    /// remember.
    private func send<Result: Decodable>(
        _ call: Call, id: Int, context: inout RequestContext
    ) async throws -> Result {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Both, always: the server picks which one it answers with.
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &request)
        request.httpBody = try call.body(id: id)

        let (data, response) = try await perform(request)

        if let assigned = response.value(forHTTPHeaderField: "Mcp-Session-Id"), !assigned.isEmpty {
            context.sessionID = assigned
        }

        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let payload: Data
        if contentType.contains("text/event-stream") {
            guard let found = JSONRPC.firstMessage(id: id, inSSE: data) else {
                throw MCPError.noResponse(call.method)
            }
            payload = found
        } else {
            payload = data
        }

        return try JSONRPC.result(Result.self, from: payload, method: call.method)
    }

    /// A notification. The server owes no answer, only a 202.
    private func notify(_ call: Call, context: RequestContext) async throws {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &request)
        request.httpBody = try call.body(id: nil)
        _ = try await perform(request)
    }

    /// Best-effort session teardown. A server may refuse with 405, which the
    /// specification allows and which is not a failure of anything the user did.
    private func endSession(_ context: RequestContext) async {
        guard context.sessionID != nil else { return }
        var request = URLRequest(url: context.url)
        request.httpMethod = "DELETE"
        context.apply(to: &request)
        _ = try? await session.data(for: request)
    }

    // MARK: - Legacy HTTP+SSE

    /// The 2024-11-05 transport: a GET that stays open, plus a POST endpoint the
    /// stream itself names.
    ///
    /// Nothing here answers the request it was sent on. Every response — and the
    /// endpoint address itself — arrives on the GET stream, in whatever order
    /// the server chooses, interleaved with notifications addressed to nobody.
    /// So the stream is drained by one task into `LegacySSESession`, which hands
    /// each message to whichever request is waiting for that id.
    private func discoverSSE(
        at url: URL, server: MCPServer, bearerToken: String?
    ) async throws -> MCPDiscovery {
        var context = RequestContext(
            url: url,
            version: Self.legacyVersion,
            sessionID: nil,
            server: server,
            bearerToken: bearerToken
        )

        var streamRequest = URLRequest(url: url)
        streamRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        context.apply(to: &streamRequest)

        let bytes: URLSession.AsyncBytes
        do {
            let (stream, raw) = try await session.bytes(for: streamRequest)
            guard let http = raw as? HTTPURLResponse else { throw MCPError.notHTTP }
            guard (200..<300).contains(http.statusCode) else {
                throw MCPError.http(status: http.statusCode)
            }
            bytes = stream
        } catch let error as URLError {
            throw MCPError.transport(error.localizedDescription)
        }

        let events = LegacySSESession()
        await events.start(SSEStream.events(from: bytes))
        // The stream is a resource, not a value: leaving it open would hold a
        // connection for the life of the process.
        defer { Task { await events.cancel() } }

        // The first thing the server says is where to POST. Usually a relative
        // path, which is why it is resolved against the stream's own URL.
        let endpoint = try await events.endpointURL()
        guard let postURL = URL(string: endpoint, relativeTo: url) else {
            throw MCPError.noEndpointEvent
        }
        context.url = postURL.absoluteURL

        let initialize: InitializeResult = try await exchange(
            .initialize(version: Self.legacyVersion), id: 1, context: context, events: events)
        context.version = initialize.protocolVersion ?? Self.legacyVersion

        try await notify(.initialized, context: context)

        var tools: [MCPTool] = []
        var cursor: String?
        var id = 2
        for _ in 0..<Self.pageLimit {
            let page: ToolsListResult = try await exchange(
                .toolsList(cursor: cursor), id: id, context: context, events: events)
            tools += (page.tools ?? []).map { $0.tool() }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
            id += 1
        }

        return MCPDiscovery(
            protocolVersion: context.version,
            serverName: initialize.serverInfo?.name ?? server.name,
            tools: tools
        )
    }

    /// POST a request, then wait for its answer to come back on the stream.
    private func exchange<Result: Decodable>(
        _ call: Call,
        id: Int,
        context: RequestContext,
        events: LegacySSESession
    ) async throws -> Result {
        var request = URLRequest(url: context.url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        context.apply(to: &request)
        request.httpBody = try call.body(id: id)
        _ = try await perform(request)

        let payload = try await events.response(id: id)
        return try JSONRPC.result(Result.self, from: payload, method: call.method)
    }

    // MARK: - Shared

    private static let pageLimit = 20

    private func listTools(context: inout RequestContext) async throws -> [MCPTool] {
        var tools: [MCPTool] = []
        var cursor: String?
        var id = 2

        for _ in 0..<Self.pageLimit {
            let page: ToolsListResult = try await send(
                .toolsList(cursor: cursor), id: id, context: &context)
            tools += (page.tools ?? []).map { $0.tool() }
            guard let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
            id += 1
        }

        return tools
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, raw) = try await session.data(for: request)
            guard let http = raw as? HTTPURLResponse else { throw MCPError.notHTTP }
            guard (200..<300).contains(http.statusCode) else {
                throw MCPError.http(status: http.statusCode)
            }
            return (data, http)
        } catch let error as URLError {
            throw MCPError.transport(error.localizedDescription)
        }
    }

    /// Everything a request needs that is not its body.
    ///
    /// `url` is a `var` because the legacy transport moves it: the stream is
    /// opened on the configured URL and every POST afterwards goes wherever the
    /// `endpoint` event pointed.
    nonisolated private struct RequestContext {
        var url: URL
        var version: String
        var sessionID: String?
        let server: MCPServer
        let bearerToken: String?

        func apply(to request: inout URLRequest) {
            request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
            if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
            if let bearerToken, !bearerToken.isEmpty {
                request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            }
            // Last, so a user who really does need to override one of the above
            // can. They configured it on purpose; we should not quietly win.
            for header in server.headers where header.isComplete {
                request.setValue(header.value, forHTTPHeaderField: header.name)
            }
        }
    }
}

// MARK: - Calls

/// The three JSON-RPC messages discovery needs.
nonisolated private enum Call {
    case initialize(version: String)
    case initialized
    case toolsList(cursor: String?)

    var method: String {
        switch self {
        case .initialize: "initialize"
        case .initialized: "notifications/initialized"
        case .toolsList: "tools/list"
        }
    }

    /// `id` is nil for notifications, which is what makes them notifications.
    func body(id: Int?) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { object["id"] = id }

        switch self {
        case .initialize(let version):
            object["params"] = [
                "protocolVersion": version,
                // Termind consumes tools and offers the server nothing back — no
                // roots, no sampling. Declaring capabilities we do not implement
                // would invite requests we would have to fail.
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Termind", "version": Bundle.termindVersion],
            ]
        case .initialized:
            object["params"] = [String: Any]()
        case .toolsList(let cursor):
            object["params"] = cursor.map { ["cursor": $0] } ?? [:]
        }

        return try JSONSerialization.data(withJSONObject: object)
    }
}

// MARK: - Wire shapes

nonisolated private struct InitializeResult: Decodable {
    var protocolVersion: String?
    var serverInfo: ServerInfo?

    nonisolated struct ServerInfo: Decodable {
        var name: String?
        var version: String?
    }
}

nonisolated private struct ToolsListResult: Decodable {
    var tools: [ToolRow]?
    var nextCursor: String?

    nonisolated struct ToolRow: Decodable {
        var name: String
        var title: String?
        var description: String?

        /// Arrives enabled and requiring approval. See `MCPTool`.
        func tool() -> MCPTool {
            MCPTool(id: name, summary: description ?? title ?? "")
        }
    }
}

/// The little bit of JSON-RPC framing this file needs.
nonisolated private enum JSONRPC {
    /// The `id` of a response, if it has one and it is a number.
    ///
    /// Termind only ever sends integer ids, so a response carrying anything else
    /// is not answering us and correlating it would be a guess.
    static func id(of data: Data) -> Int? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["id"] as? Int
    }

    /// Finds our response inside an SSE body.
    ///
    /// A server answering a POST with a stream may send notifications ahead of
    /// the response — progress, logging — so this scans for the id rather than
    /// taking the first message.
    ///
    /// Framing is left to `SSEStream` rather than re-split here. Two SSE
    /// parsers in one codebase is one too many, and this is the copy that would
    /// have drifted.
    static func firstMessage(id: Int, inSSE data: Data) -> Data? {
        for event in SSEStream.events(in: data) {
            guard let bytes = event.data.data(using: .utf8), Self.id(of: bytes) == id else { continue }
            return bytes
        }
        return nil
    }

    nonisolated struct Envelope<R: Decodable>: Decodable {
        var result: R?
        var error: RPCError?
    }

    nonisolated struct RPCError: Decodable {
        var code: Int?
        var message: String?
    }

    /// Unwraps `{"result": …}`, or turns `{"error": …}` into a thrown error.
    static func result<T: Decodable>(_ type: T.Type, from data: Data, method: String) throws -> T {
        guard let envelope = try? JSONDecoder().decode(Envelope<T>.self, from: data) else {
            throw MCPError.malformedResponse(method)
        }
        if let error = envelope.error {
            throw MCPError.rpc(
                method: method,
                code: error.code ?? 0,
                message: error.message ?? String(localized: "no reason given")
            )
        }
        guard let result = envelope.result else { throw MCPError.malformedResponse(method) }
        return result
    }
}

// MARK: - Errors

nonisolated enum MCPError: Error, LocalizedError, Equatable, Sendable {
    case badURL(String)
    case notHTTP
    case http(status: Int)
    case transport(String)
    case wrongTransport(status: Int)
    case noEndpointEvent
    case streamClosed
    case noResponse(String)
    case malformedResponse(String)
    case rpc(method: String, code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .badURL(let value):
            String(localized: "\(value) is not an http or https URL.")
        case .notHTTP:
            String(localized: "The server did not answer with HTTP.")
        case .http(let status):
            String(localized: "The server answered \(status).")
        case .transport(let message):
            message
        case .wrongTransport(let status):
            String(
                localized:
                    "The server answered \(status) to a Streamable HTTP request. It may only speak the legacy SSE transport — try switching Transport."
            )
        case .noEndpointEvent:
            String(
                localized:
                    "The stream opened but never named a POST endpoint. This may be a Streamable HTTP server — try switching Transport."
            )
        case .streamClosed:
            String(localized: "The server closed the stream before answering.")
        case .noResponse(let method):
            String(localized: "The server never answered \(method).")
        case .malformedResponse(let method):
            String(localized: "The server's answer to \(method) was not valid MCP.")
        case .rpc(let method, let code, let message):
            String(localized: "\(method) failed (\(code)): \(message)")
        }
    }
}

// MARK: - Reading the legacy stream

/// Drains a legacy SSE stream and matches what arrives to what is waiting.
///
/// An actor with a pump task rather than an iterator passed between functions,
/// and for two reasons that point the same way.
///
/// The design reason: on this transport a POST does not carry its own answer.
/// Responses come back on a stream that was opened *before* the request went
/// out, out of order, mixed in with notifications nobody asked for. Correlating
/// by JSON-RPC id is the transport's actual contract, and this is that contract
/// written down.
///
/// The concurrency reason: an `AsyncIterator` is not `Sendable`, so it cannot be
/// pulled one event at a time across `async` calls without the compiler
/// objecting — rightly, since the caller could touch it across a suspension. A
/// `for try await` loop inside one task has no such problem, and the actor gives
/// the results somewhere safe to land.
private actor LegacySSESession {
    /// Where to POST, once the server has said.
    private var endpoint: String?
    private var endpointWaiter: CheckedContinuation<String, any Error>?

    /// Responses that arrived before anyone asked — which happens whenever the
    /// server is quicker than the caller's next line.
    private var delivered: [Int: Data] = [:]
    private var waiters: [Int: CheckedContinuation<Data, any Error>] = [:]

    /// Set once the stream ends, for any reason. Every later wait fails with it
    /// immediately rather than hanging on a stream that is not coming back.
    private var failure: (any Error)?

    private var pump: Task<Void, Never>?

    func start(_ stream: AsyncThrowingStream<SSEEvent, any Error>) {
        // Inherits this actor's isolation, so `receive` and `finish` need no
        // hop and the mutable state below has exactly one writer.
        pump = Task { [self] in
            do {
                for try await event in stream {
                    receive(event)
                }
                // A stream that closes cleanly has still stopped answering.
                finish(MCPError.streamClosed)
            } catch {
                finish(error)
            }
        }
    }

    func cancel() {
        pump?.cancel()
        pump = nil
    }

    func endpointURL() async throws -> String {
        if let endpoint { return endpoint }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            endpointWaiter = continuation
        }
    }

    func response(id: Int) async throws -> Data {
        if let ready = delivered.removeValue(forKey: id) { return ready }
        if let failure { throw failure }
        return try await withCheckedThrowingContinuation { continuation in
            waiters[id] = continuation
        }
    }

    private func receive(_ event: SSEEvent) {
        if event.event == "endpoint" {
            endpoint = event.data
            endpointWaiter?.resume(returning: event.data)
            endpointWaiter = nil
            return
        }

        // Anything without an integer id is a notification or a response to
        // somebody else. Termind only ever sends integer ids, so correlating
        // anything else would be a guess.
        guard let data = event.data.data(using: .utf8), let id = JSONRPC.id(of: data) else { return }

        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(returning: data)
        } else {
            delivered[id] = data
        }
    }

    private func finish(_ error: any Error) {
        guard failure == nil else { return }
        failure = error

        endpointWaiter?.resume(throwing: error)
        endpointWaiter = nil
        for (_, waiter) in waiters { waiter.resume(throwing: error) }
        waiters.removeAll()
    }
}

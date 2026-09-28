import Foundation
import Network
import TermindDomain
import TermindRemoteInfrastructure

import struct TermindDomain.Host

nonisolated struct HTTPRequest: Sendable {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

nonisolated struct HTTPResponse: Sendable {
    nonisolated enum Body: Sendable {
        case data(Data)
        case stream(AsyncStream<Data>)
        case file(HTTPFileBody)
    }

    var status: Int
    var headers: [String: String]
    var body: Body

    init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = .data(body)
    }

    init(status: Int, headers: [String: String] = [:], stream: AsyncStream<Data>) {
        self.status = status
        self.headers = headers
        body = .stream(stream)
    }

    init(status: Int, headers: [String: String] = [:], file: HTTPFileBody) {
        self.status = status
        self.headers = headers
        body = .file(file)
    }

    static func text(_ status: Int, _ value: String, headers: [String: String] = [:]) -> Self {
        var all = headers
        all["Content-Type"] = "text/plain; charset=utf-8"
        return Self(status: status, headers: all, body: Data(value.utf8))
    }
}

nonisolated struct HTTPFileBody: Sendable {
    var byteCount: Int64
    var read: @Sendable () async throws -> Data?
    var sent: @Sendable (Int) async -> Void
    var finished: @Sendable (Result<Void, any Error>) async -> Void
    var cancel: @Sendable () -> Void
}

nonisolated enum HTTPStreamingDecision: Sendable {
    case reject(HTTPResponse)
    case accept(
        @Sendable (@escaping SFTPStreamUploadOperation.ReadChunk) async -> HTTPResponse,
        disconnected: @Sendable () -> Void
    )
}

actor LoopbackHTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    typealias StreamingHandler = @Sendable (HTTPRequest) async -> HTTPStreamingDecision
    typealias DownloadHandler =
        @Sendable (
            HTTPRequest, TransferCancellationToken, @escaping @Sendable () -> Void
        ) async -> HTTPResponse
    typealias StateHandler = @Sendable (State) -> Void

    nonisolated enum State: Sendable, Equatable {
        case stopped
        case starting
        case ready(port: UInt16)
        case failed(String)
    }

    static let maximumHeaderBytes = 64 * 1_024
    static let maximumBodyBytes = 4 * 1_024 * 1_024
    static let maximumConnections = 64

    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var token = ""
    private var handler: Handler?
    private var streamingHandler: StreamingHandler?
    private var downloadHandler: DownloadHandler?
    private var stateHandler: StateHandler?
    private var readyListeners = 0

    func start(
        port: UInt16, token: String,
        stateHandler: @escaping StateHandler = { _ in },
        streamingHandler: StreamingHandler? = nil,
        downloadHandler: DownloadHandler? = nil,
        handler: @escaping Handler
    ) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port), !token.isEmpty else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        self.token = token
        self.handler = handler
        self.streamingHandler = streamingHandler
        self.downloadHandler = downloadHandler
        self.stateHandler = stateHandler
        stateHandler(.starting)

        do {
            listeners = try ["127.0.0.1", "::1"].map { address in
                let tcp = NWProtocolTCP.Options()
                tcp.enableKeepalive = true
                tcp.keepaliveIdle = 60
                tcp.keepaliveInterval = 10
                tcp.keepaliveCount = 3
                tcp.connectionTimeout = 15
                let parameters = NWParameters(tls: nil, tcp: tcp)
                parameters.acceptLocalOnly = true
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(address), port: endpointPort
                )
                let listener = try NWListener(using: parameters)
                listener.newConnectionLimit = Self.maximumConnections
                listener.newConnectionHandler = { [weak self] connection in
                    Task { await self?.accept(connection) }
                }
                listener.stateUpdateHandler = { [weak self] newState in
                    Task { await self?.listenerChanged(newState, port: port) }
                }
                listener.start(queue: DispatchQueue(label: "termind.mcp.listener.\(address)"))
                return listener
            }
        } catch {
            stop()
            throw error
        }
    }

    func replaceToken(_ token: String) {
        self.token = token
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    func stop() {
        for listener in listeners { listener.cancel() }
        for connection in connections.values { connection.cancel() }
        listeners.removeAll()
        connections.removeAll()
        handler = nil
        streamingHandler = nil
        downloadHandler = nil
        readyListeners = 0
        stateHandler?(.stopped)
        stateHandler = nil
    }

    private func listenerChanged(_ newState: NWListener.State, port: UInt16) {
        switch newState {
        case .ready:
            readyListeners += 1
            if readyListeners == listeners.count {
                stateHandler?(.ready(port: port))
            }
        case .failed(let error):
            stateHandler?(.failed(error.localizedDescription))
            for listener in listeners { listener.cancel() }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) async {
        guard connections.count < Self.maximumConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: DispatchQueue(label: "termind.mcp.connection"))
        defer {
            connections[id] = nil
            connection.cancel()
        }

        var buffer = Data()
        while !Task.isCancelled {
            let parsed: (HTTPRequest, Data)
            do {
                parsed = try await Self.readRequestHead(connection, initial: buffer)
                buffer = parsed.1
            } catch LoopbackHTTPServerError.endOfStream {
                return
            } catch LoopbackHTTPServerError.headersTooLarge {
                try? await Self.send(.text(431, "Request headers are too large."), on: connection)
                return
            } catch LoopbackHTTPServerError.bodyTooLarge {
                try? await Self.send(.text(413, "Request body is too large."), on: connection)
                return
            } catch LoopbackHTTPServerError.chunkedRequest {
                try? await Self.send(.text(411, "Chunked request bodies are not supported."), on: connection)
                return
            } catch {
                try? await Self.send(.text(400, "Malformed HTTP request."), on: connection)
                return
            }

            let request = parsed.0
            // Browsers cannot attach bearer credentials to CORS preflights. Only
            // validated loopback origins may probe the MCP routes; no RPC is run.
            if request.method == "OPTIONS", Self.isMCPRoute(request.target) {
                var response = Self.preflightResponse(request)
                response.headers["Connection"] = "close"
                try? await Self.send(response, on: connection)
                return
            }
            if request.target.hasPrefix("/downloads/") {
                guard let downloadHandler else {
                    try? await Self.send(.text(404, "Unknown download route."), on: connection)
                    return
                }
                let cancellation = TransferCancellationToken()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .failed, .cancelled: cancellation.cancel()
                    default: break
                    }
                }
                var downloadRequest = request
                downloadRequest.body = buffer
                var response = await downloadHandler(downloadRequest, cancellation, { connection.cancel() })
                response.headers["Connection"] = "close"
                try? await Self.send(response, on: connection)
                connection.stateUpdateHandler = nil
                return
            }
            // Uploads use a scoped capability, not the long-lived MCP token. No body
            // is drained before route-specific authorization and atomic claiming.
            if request.target.hasPrefix("/uploads/") {
                guard Self.allowedOrigin(request.header("origin")) else {
                    try? await Self.send(.text(403, "The request Origin is not loopback."), on: connection)
                    return
                }
                guard let streamingHandler else {
                    try? await Self.send(.text(404, "Unknown upload route."), on: connection)
                    return
                }
                switch await streamingHandler(request) {
                case .reject(var response):
                    response.headers["Connection"] = "close"
                    try? await Self.send(response, on: connection)
                case .accept(let consume, let disconnected):
                    connection.stateUpdateHandler = { state in
                        switch state {
                        case .failed, .cancelled: disconnected()
                        default: break
                        }
                    }
                    if request.header("expect")?.lowercased() == "100-continue" {
                        do { try await Self.send(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), on: connection) } catch {
                            disconnected()
                            return
                        }
                    }
                    let reader = HTTPUploadBodyReader(
                        connection: connection, initial: buffer,
                        byteCount: Int64(request.header("content-length") ?? "") ?? 0
                    )
                    var response = await consume { try await reader.next() }
                    response.headers["Connection"] = "close"
                    // Do not turn a committed upload into a failure if its response
                    // is lost. The disconnected callback only cancels live work.
                    connection.stateUpdateHandler = nil
                    try? await Self.send(response, on: connection)
                }
                return
            }
            let response: HTTPResponse
            if !Self.authorized(request, token: token) {
                response = .text(
                    401, "A valid bearer token is required.",
                    headers: ["WWW-Authenticate": "Bearer"]
                )
            } else if !Self.allowedOrigin(request.header("origin")) {
                response = .text(403, "The request Origin is not loopback.")
            } else if let handler {
                do {
                    var buffered = request
                    let length = Int(request.header("content-length") ?? "0") ?? 0
                    guard length <= Self.maximumBodyBytes else { throw LoopbackHTTPServerError.bodyTooLarge }
                    while buffer.count < length { buffer.append(try await Self.receive(connection)) }
                    buffered.body = Data(buffer.prefix(length))
                    buffer.removeFirst(length)
                    response = await handler(buffered)
                } catch LoopbackHTTPServerError.bodyTooLarge {
                    try? await Self.send(.text(413, "Request body is too large."), on: connection)
                    return
                } catch { return }
            } else {
                response = .text(503, "The MCP server is stopping.")
            }
            // An unauthenticated body has not been consumed and cannot be treated
            // as the next request on a persistent connection.
            var outgoing = response
            if Self.isMCPRoute(request.target) {
                Self.addCORSHeaders(to: &outgoing, request: request)
            }
            if response.status == 401 || response.status == 403 { outgoing.headers["Connection"] = "close" }
            do { try await Self.send(outgoing, on: connection) } catch { return }
            if response.status == 401 || response.status == 403 { return }
            if case .stream = response.body { return }
            if case .file = response.body { return }
            let connectionHeader = request.header("connection")?.lowercased()
            let keepAlive =
                request.version == "HTTP/1.1"
                ? connectionHeader != "close" : connectionHeader == "keep-alive"
            if !keepAlive { return }
        }
    }

    private static func isMCPRoute(_ target: String) -> Bool {
        guard let path = URLComponents(string: target)?.path else { return false }
        return ["/mcp", "/sse", "/messages"].contains(path)
    }

    private static func addCORSHeaders(to response: inout HTTPResponse, request: HTTPRequest) {
        guard let origin = request.header("origin"), allowedOrigin(origin) else { return }
        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Expose-Headers"] = "Mcp-Session-Id, MCP-Protocol-Version, WWW-Authenticate"
        response.headers["Vary"] = "Origin"
    }

    private static func preflightResponse(_ request: HTTPRequest) -> HTTPResponse {
        guard request.header("origin") != nil, allowedOrigin(request.header("origin")) else {
            return .text(403, "The request Origin is not loopback.")
        }
        let path = URLComponents(string: request.target)?.path
        let methods = path == "/mcp" ? ["POST", "GET", "DELETE"] : (path == "/sse" ? ["GET"] : ["POST"])
        guard let method = request.header("access-control-request-method"), methods.contains(method) else {
            var response = HTTPResponse.text(405, "The requested MCP method is not allowed.")
            addCORSHeaders(to: &response, request: request)
            return response
        }
        let headers = (request.header("access-control-request-headers") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        let allowed = Set([
            "authorization", "content-type", "accept", "mcp-session-id", "mcp-protocol-version",
            "mcp-method", "mcp-name", "last-event-id",
        ])
        guard headers.allSatisfy({ allowed.contains($0) }) else {
            var response = HTTPResponse.text(400, "The requested MCP headers are not allowed.")
            addCORSHeaders(to: &response, request: request)
            return response
        }
        var response = HTTPResponse(status: 204)
        addCORSHeaders(to: &response, request: request)
        response.headers["Access-Control-Allow-Methods"] = methods.joined(separator: ", ")
        response.headers["Access-Control-Allow-Headers"] = headers.joined(separator: ", ")
        response.headers["Vary"] = "Origin, Access-Control-Request-Method, Access-Control-Request-Headers"
        return response
    }

    private static func authorized(_ request: HTTPRequest, token: String) -> Bool {
        guard let value = request.header("authorization"), value.hasPrefix("Bearer ") else {
            return false
        }
        return constantTimeEqual(String(value.dropFirst(7)), token)
    }

    static func constantTimeEqual(_ left: String, _ right: String) -> Bool {
        let a = Array(left.utf8)
        let b = Array(right.utf8)
        let count = max(a.count, b.count)
        var difference = a.count ^ b.count
        for index in 0..<count {
            difference |=
                Int(index < a.count ? a[index] : 0)
                ^ Int(index < b.count ? b[index] : 0)
        }
        return difference == 0
    }

    static func allowedOrigin(_ raw: String?) -> Bool {
        guard let raw else { return true }
        guard let components = URLComponents(string: raw),
            components.scheme == "http" || components.scheme == "https",
            components.user == nil, components.password == nil,
            components.path.isEmpty, components.query == nil, components.fragment == nil,
            let rawHost = components.host?.lowercased()
        else { return false }
        let host =
            rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
            ? String(rawHost.dropFirst().dropLast()) : rawHost
        if host == "localhost" || host == "::1" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
            parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } })
        else { return false }
        let octets = parts.compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 127
    }

    private static func readRequestHead(
        _ connection: NWConnection, initial: Data
    ) async throws -> (HTTPRequest, Data) {
        var buffer = initial
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            guard buffer.count <= maximumHeaderBytes else {
                throw LoopbackHTTPServerError.headersTooLarge
            }
            buffer.append(try await receive(connection))
        }
        guard let range = buffer.range(of: separator), range.lowerBound <= maximumHeaderBytes else {
            throw LoopbackHTTPServerError.headersTooLarge
        }
        let head = buffer[..<range.lowerBound]
        guard let text = String(data: head, encoding: .utf8) else {
            throw LoopbackHTTPServerError.malformed
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw LoopbackHTTPServerError.malformed }
        let requestLine = first.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/") else {
            throw LoopbackHTTPServerError.malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                throw LoopbackHTTPServerError.malformed
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { throw LoopbackHTTPServerError.malformed }
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let byteRoute = String(requestLine[1]).hasPrefix("/uploads/") || String(requestLine[1]).hasPrefix("/downloads/")
        if headers["transfer-encoding"] != nil && !byteRoute {
            throw LoopbackHTTPServerError.chunkedRequest
        }
        if let raw = headers["content-length"] {
            if !byteRoute {
                guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), Int(raw) != nil else {
                    throw LoopbackHTTPServerError.malformed
                }
            }
        }
        let remainder = Data(buffer[range.upperBound...])
        return (
            HTTPRequest(
                method: String(requestLine[0]), target: String(requestLine[1]),
                version: String(requestLine[2]), headers: headers, body: Data()
            ), remainder
        )
    }

    fileprivate static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
                data, _, complete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: LoopbackHTTPServerError.endOfStream)
                } else {
                    continuation.resume(throwing: LoopbackHTTPServerError.malformed)
                }
            }
        }
    }

    private static func send(_ response: HTTPResponse, on connection: NWConnection) async throws {
        var headers = response.headers
        headers["Server"] = "Termind"
        headers["Cache-Control"] = headers["Cache-Control"] ?? "no-store"
        let prefix: Data
        switch response.body {
        case .data(let body):
            headers["Content-Length"] = String(body.count)
            headers["Connection"] = headers["Connection"] ?? "keep-alive"
            prefix = responseHead(status: response.status, headers: headers)
            try await send(prefix + body, on: connection)
        case .stream(let stream):
            headers["Connection"] = "close"
            prefix = responseHead(status: response.status, headers: headers)
            try await send(prefix, on: connection)
            for await chunk in stream { try await send(chunk, on: connection) }
        case .file(let file):
            headers["Content-Length"] = String(file.byteCount)
            headers["Connection"] = "close"
            prefix = responseHead(status: response.status, headers: headers)
            await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    try await send(prefix, on: connection)
                    var sent: Int64 = 0
                    while let chunk = try await file.read() {
                        guard !chunk.isEmpty, chunk.count <= 64 * 1_024,
                            Int64(chunk.count) <= file.byteCount - sent
                        else { throw SFTPDownloadFailure.invalidChunk }
                        try await send(chunk, on: connection)
                        sent += Int64(chunk.count)
                        await file.sent(chunk.count)
                    }
                    guard sent == file.byteCount else { throw SFTPDownloadFailure.sourceChanged }
                    await file.finished(.success(()))
                } catch {
                    await file.finished(.failure(error))
                    connection.cancel()
                }
            } onCancel: {
                file.cancel()
                connection.cancel()
            }
        }
    }

    private static func responseHead(status: Int, headers: [String: String]) -> Data {
        var value = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, headerValue) in headers.sorted(by: { $0.key < $1.key }) {
            value += "\(name): \(headerValue)\r\n"
        }
        value += "\r\n"
        return Data(value.utf8)
    }

    private static func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 204: "No Content"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 410: "Gone"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 416: "Range Not Satisfiable"
        case 417: "Expectation Failed"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        case 502: "Bad Gateway"
        case 504: "Gateway Timeout"
        default: "Error"
        }
    }
}

/// Keeps at most one network chunk plus the bounded remainder of the header read.
private actor HTTPUploadBodyReader {
    let connection: NWConnection
    var buffer: Data
    var remaining: Int64

    init(connection: NWConnection, initial: Data, byteCount: Int64) {
        self.connection = connection
        buffer = initial
        remaining = byteCount
    }

    func next() async throws -> Data? {
        guard remaining > 0 else { return nil }
        try Task.checkCancellation()
        if buffer.isEmpty {
            let connection = connection
            let timedOut = TransferCancellationToken()
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                timedOut.cancel()
                connection.cancel()
            }
            defer { timeout.cancel() }
            do {
                buffer = try await withTaskCancellationHandler {
                    try await LoopbackHTTPServer.receive(connection)
                } onCancel: {
                    connection.cancel()
                }
            } catch {
                if timedOut.isCancelled { throw SFTPStreamUploadOperation.Failure.timedOut }
                throw error
            }
        }
        let count = Int(min(remaining, Int64(min(buffer.count, SFTPStreamUploadOperation.chunkBytes))))
        let chunk = Data(buffer.prefix(count))
        buffer.removeFirst(count)
        remaining -= Int64(count)
        return chunk
    }
}

nonisolated enum LoopbackHTTPServerError: Error, Sendable {
    case invalidConfiguration, malformed, headersTooLarge, bodyTooLarge, chunkedRequest, endOfStream
}

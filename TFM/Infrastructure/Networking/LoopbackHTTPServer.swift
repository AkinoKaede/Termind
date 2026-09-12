import Foundation
import Network
import TermindDomain

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

    static func text(_ status: Int, _ value: String, headers: [String: String] = [:]) -> Self {
        var all = headers
        all["Content-Type"] = "text/plain; charset=utf-8"
        return Self(status: status, headers: all, body: Data(value.utf8))
    }
}

actor LoopbackHTTPServer {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
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
    private var stateHandler: StateHandler?
    private var readyListeners = 0

    func start(
        port: UInt16, token: String,
        stateHandler: @escaping StateHandler = { _ in },
        handler: @escaping Handler
    ) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port), !token.isEmpty else {
            throw LoopbackHTTPServerError.invalidConfiguration
        }
        self.token = token
        self.handler = handler
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
                parsed = try await Self.readRequest(connection, initial: buffer)
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
            let response: HTTPResponse
            if !Self.authorized(request, token: token) {
                response = .text(
                    401, "A valid bearer token is required.",
                    headers: ["WWW-Authenticate": "Bearer"]
                )
            } else if !Self.allowedOrigin(request.header("origin")) {
                response = .text(403, "The request Origin is not loopback.")
            } else if let handler {
                response = await handler(request)
            } else {
                response = .text(503, "The MCP server is stopping.")
            }
            do { try await Self.send(response, on: connection) } catch { return }
            if case .stream = response.body { return }
            let connectionHeader = request.header("connection")?.lowercased()
            let keepAlive =
                request.version == "HTTP/1.1"
                ? connectionHeader != "close" : connectionHeader == "keep-alive"
            if !keepAlive { return }
        }
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
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        return octets.count == 4 && octets[0] == 127
    }

    private static func readRequest(
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
        if headers["transfer-encoding"] != nil {
            throw LoopbackHTTPServerError.chunkedRequest
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard let parsed = Int(raw), parsed >= 0 else { throw LoopbackHTTPServerError.malformed }
            length = parsed
        } else {
            length = 0
        }
        guard length <= maximumBodyBytes else { throw LoopbackHTTPServerError.bodyTooLarge }
        var remainder = Data(buffer[range.upperBound...])
        while remainder.count < length { remainder.append(try await receive(connection)) }
        let body = Data(remainder.prefix(length))
        remainder.removeFirst(length)
        return (
            HTTPRequest(
                method: String(requestLine[0]), target: String(requestLine[1]),
                version: String(requestLine[2]), headers: headers, body: body
            ), remainder
        )
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
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
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 503: "Service Unavailable"
        default: "Error"
        }
    }
}

nonisolated enum LoopbackHTTPServerError: Error, Sendable {
    case invalidConfiguration, malformed, headersTooLarge, bodyTooLarge, chunkedRequest, endOfStream
}

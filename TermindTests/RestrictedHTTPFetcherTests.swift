import Darwin
import Foundation
import Testing

@testable import Termind

@Suite(.serialized)
struct RestrictedHTTPFetcherTests {
    @Test(arguments: [
        "http://127.0.0.1/", "http://10.0.0.1/", "http://100.64.0.1/",
        "http://169.254.169.254/", "http://192.0.2.1/", "http://[::1]/",
        "http://[fc00::1]/", "http://[fe80::1]/",
    ])
    func classifiesNonPublicUnicastAsRestricted(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        #expect(try await PublicAddressValidator.classify(url) == .restricted)
    }

    @Test(arguments: ["http://8.8.8.8/", "https://1.1.1.1/"])
    func classifiesGloballyRoutableUnicastAsPublic(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        #expect(try await PublicAddressValidator.classify(url) == .publicInternet)
    }

    @Test(arguments: [
        "file:///etc/passwd", "http://user:pass@example.com/", "http://0.0.0.0/",
        "http://224.0.0.1/", "http://[ff02::1]/",
    ])
    func rejectsNonHTTPEmbeddedCredentialsAndNonUnicastTargets(_ raw: String) async throws {
        let url = try #require(URL(string: raw))
        await #expect(throws: (any Error).self) {
            try await PublicAddressValidator.classify(url)
        }
    }

    @Test
    func validatesHeaderSyntaxLimitsAndTransportOwnedNames() throws {
        let valid = [
            RestrictedHTTPHeader(name: "Accept", value: "application/json"),
            RestrictedHTTPHeader(name: "Authorization", value: "Bearer abc"),
            RestrictedHTTPHeader(name: "X-Trace_ID", value: "one"),
        ]
        #expect(try RestrictedHTTPHeaderValidator.validate(valid) == valid)

        for header in [
            RestrictedHTTPHeader(name: "Bad Header", value: "x"),
            RestrictedHTTPHeader(name: ":authority", value: "x"),
            RestrictedHTTPHeader(name: "Host", value: "example.test"),
            RestrictedHTTPHeader(name: "Content-Length", value: "10"),
            RestrictedHTTPHeader(name: "X-Test", value: "one\r\ntwo"),
            RestrictedHTTPHeader(name: "X-Test", value: "one\u{0}two"),
        ] {
            #expect(throws: RestrictedFetchError.self) {
                try RestrictedHTTPHeaderValidator.validate([header])
            }
        }
        #expect(throws: RestrictedFetchError.self) {
            try RestrictedHTTPHeaderValidator.validate(
                (0...RestrictedHTTPHeaderValidator.maximumCount).map {
                    RestrictedHTTPHeader(name: "X-\($0)", value: "x")
                }
            )
        }
        #expect(throws: RestrictedFetchError.self) {
            try RestrictedHTTPHeaderValidator.validate([
                RestrictedHTTPHeader(
                    name: "X-Large",
                    value: String(
                        repeating: "x", count: RestrictedHTTPHeaderValidator.maximumValueBytes + 1
                    )
                )
            ])
        }
        #expect(throws: RestrictedFetchError.self) {
            try RestrictedHTTPHeaderValidator.validate(
                (0..<9).map {
                    RestrictedHTTPHeader(
                        name: "X-Large-\($0)",
                        value: String(repeating: "x", count: 8_000)
                    )
                }
            )
        }
    }

    @Test
    func fetchPreflightOnlyEscalatesRestrictedDestinations() async throws {
        let arguments: AgentJSONValue = .object([
            "url": .string("https://example.test/data"),
            "headers": .array([
                .object([
                    "name": .string("Authorization"), "value": .string("Bearer abc"),
                ])
            ]),
        ])
        let invocation = AgentToolInvocation(
            runID: UUID(), call: AgentToolCall(id: "fetch", name: "fetch", arguments: arguments)
        )
        let publicTool = AgentBuiltInTools.fetch(
            RestrictedHTTPFetcher(classifier: { _ in
                .publicInternet
            }))
        let restrictedTool = AgentBuiltInTools.fetch(
            RestrictedHTTPFetcher(classifier: { _ in
                .restricted
            }))

        #expect(try await publicTool.preflight(invocation).safety == .locallyReadOnly)
        let restricted = try await restrictedTool.preflight(invocation)
        #expect(restricted.safety == .requiresAuthorization)
        #expect(restricted.reasons.first?.contains("non-public network") == true)
        #expect(
            restricted.executionMetadata["authorized_fetch_origins"]?.arrayValue?.count == 1
        )
    }

    @Test
    func sendsCustomAndDuplicateHeadersAndBoundsTheResponse() async throws {
        let requests = LockedRequests()
        let server = try LocalHTTPServer { request in
            requests.append(request)
            return Self.response(body: "abcdefgh")
        }
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/data"
        let origin = try PublicAddressValidator.origin(of: #require(URL(string: url)))
        let fetcher = RestrictedHTTPFetcher(maximumBytes: 4)
        let response = try await fetcher.fetch(
            url, method: "GET",
            headers: [
                RestrictedHTTPHeader(name: "X-Trace", value: "one"),
                RestrictedHTTPHeader(name: "X-Trace", value: "two"),
                RestrictedHTTPHeader(name: "User-Agent", value: "Custom Agent"),
            ],
            authorizedRestrictedOrigins: [origin]
        )

        #expect(response.body == "abcd")
        #expect(response.truncated)
        let request = try #require(requests.values.first)
        #expect(request.hasPrefix("GET /data HTTP/1.1"))
        #expect(request.localizedCaseInsensitiveContains("User-Agent: Custom Agent"))
        let one = try #require(request.range(of: "one"))
        let two = try #require(request.range(of: "two"))
        #expect(one.lowerBound < two.lowerBound)
    }

    @Test
    func headReturnsNoBody() async throws {
        let requests = LockedRequests()
        let server = try LocalHTTPServer { request in
            requests.append(request)
            return Self.response(body: "ignored")
        }
        defer { server.stop() }
        let url = "http://127.0.0.1:\(server.port)/head"
        let origin = try PublicAddressValidator.origin(of: #require(URL(string: url)))
        let response = try await RestrictedHTTPFetcher().fetch(
            url, method: "HEAD", authorizedRestrictedOrigins: [origin]
        )

        #expect(response.body.isEmpty)
        #expect(requests.values.first?.hasPrefix("HEAD /head HTTP/1.1") == true)
    }

    @Test
    func redirectIntoRestrictedOriginPausesOnceAndKeepsHeadersAcrossHostChange() async throws {
        let requests = LockedRequests()
        let authorizations = LockedRequests()
        let redirectPort = LockedPort()
        let server = try LocalHTTPServer { request in
            requests.append(request)
            if request.contains("GET /start ") {
                return Self.redirect("http://localhost:\(redirectPort.value)/private")
            }
            if request.contains("GET /private ") { return Self.redirect("/private-again") }
            if request.contains("GET /private-again ") {
                return Self.redirect("http://127.0.0.1:\(redirectPort.value)/final")
            }
            return Self.response(body: "done")
        }
        redirectPort.value = server.port
        defer { server.stop() }
        let fetcher = RestrictedHTTPFetcher(classifier: { url in
            url.path == "/start" ? .publicInternet : .restricted
        })
        let response = try await fetcher.fetch(
            "http://127.0.0.1:\(server.port)/start", method: "GET",
            headers: [RestrictedHTTPHeader(name: "Authorization", value: "Bearer cross-origin")],
            authorizeRestrictedOrigin: { _, origin in authorizations.append(origin) }
        )

        #expect(response.body == "done")
        #expect(authorizations.values.count == 2)
        #expect(Set(authorizations.values).count == 2)
        #expect(requests.values.count == 4)
        #expect(
            requests.values.allSatisfy {
                $0.localizedCaseInsensitiveContains("Authorization: Bearer cross-origin")
            })
    }

    @Test
    func deniedRedirectNeverConnectsToRestrictedTarget() async throws {
        let requests = LockedRequests()
        let server = try LocalHTTPServer { request in
            requests.append(request)
            return Self.redirect("/private")
        }
        defer { server.stop() }
        let fetcher = RestrictedHTTPFetcher(classifier: { url in
            url.path == "/start" ? .publicInternet : .restricted
        })

        await #expect(throws: RestrictedFetchError.self) {
            try await fetcher.fetch(
                "http://127.0.0.1:\(server.port)/start", method: "GET",
                authorizeRestrictedOrigin: { _, _ in
                    throw RestrictedFetchError.authorizationDenied("denied in test")
                }
            )
        }
        #expect(requests.values.count == 1)
    }

    @Test
    func enforcesTheRedirectLimit() async throws {
        let requests = LockedRequests()
        let server = try LocalHTTPServer { request in
            requests.append(request)
            return Self.redirect("/again")
        }
        defer { server.stop() }
        let fetcher = RestrictedHTTPFetcher(
            maximumRedirects: 2, classifier: { _ in .publicInternet }
        )

        await #expect(throws: RestrictedFetchError.self) {
            try await fetcher.fetch(
                "http://127.0.0.1:\(server.port)/start", method: "GET"
            )
        }
        #expect(requests.values.count == 3)
    }

    @Test
    func sensitiveHeaderValuesAreRedactedStructurally() {
        let arguments: AgentJSONValue = .object([
            "headers": .array([
                .object(["name": .string("Authorization"), "value": .string("Bearer abc")]),
                .object(["name": .string("Cookie"), "value": .string("sid=secret")]),
                .object(["name": .string("X-Trace"), "value": .string("visible")]),
            ])
        ])
        let encoded = AgentSensitiveDataRedactor.redactedJSON(arguments).encodedString
        #expect(!encoded.contains("Bearer abc"))
        #expect(!encoded.contains("sid=secret"))
        #expect(encoded.contains("visible"))
        #expect(encoded.components(separatedBy: "[REDACTED]").count == 3)
    }

    nonisolated private static func response(body: String) -> String {
        "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
    }

    nonisolated private static func redirect(_ location: String) -> String {
        "HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    }
}

nonisolated private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }
    func append(_ value: String) { lock.withLock { storage.append(value) } }
}

nonisolated private final class LockedPort: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

nonisolated private final class LocalHTTPServer: @unchecked Sendable {
    let port: Int
    private let descriptor: Int32
    private let handler: @Sendable (String) -> String
    private let lock = NSLock()
    private var stopped = false
    private let queue = DispatchQueue(label: "RestrictedHTTPFetcherTests.LocalHTTPServer")

    init(handler: @escaping @Sendable (String) -> String) throws {
        self.handler = handler
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw LocalHTTPServerError.socket }
        descriptor = socketDescriptor
        var reuse: Int32 = 1
        guard
            setsockopt(
                socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &reuse,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0
        else {
            Darwin.close(socketDescriptor)
            throw LocalHTTPServerError.socket
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(socketDescriptor, 8) == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalHTTPServerError.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(socketDescriptor)
            throw LocalHTTPServerError.socket
        }
        port = Int(UInt16(bigEndian: address.sin_port))
        queue.async { [self] in acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldClose {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func acceptLoop() {
        while !lock.withLock({ stopped }) {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil, data.count < 64 * 1_024 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let response = Data(handler(String(decoding: data, as: UTF8.self)).utf8)
        response.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            _ = send(client, base, bytes.count, 0)
        }
    }
}

nonisolated private enum LocalHTTPServerError: Error { case socket }

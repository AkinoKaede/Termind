import Darwin
import Foundation

nonisolated struct RestrictedHTTPResponse: Sendable {
    var url: URL
    var status: Int
    var headers: [String: String]
    var body: String
    var truncated: Bool
}

nonisolated struct RestrictedHTTPHeader: Hashable, Sendable {
    var name: String
    var value: String
}

nonisolated enum RestrictedNetworkScope: Hashable, Sendable {
    case publicInternet
    case restricted
}

/// A bounded HTTP(S) fetcher. Public destinations may execute as locally
/// read-only work; non-public unicast destinations are admitted only after the
/// caller authorizes their origin. DNS and authorization are repeated at each
/// redirect boundary.
nonisolated struct RestrictedHTTPFetcher: Sendable {
    typealias Classifier = @Sendable (URL) async throws -> RestrictedNetworkScope
    typealias RestrictedOriginAuthorizer = @Sendable (URL, String) async throws -> Void

    var maximumBytes: Int
    var timeout: TimeInterval
    var maximumRedirects: Int
    private let classifyURL: Classifier

    init(
        maximumBytes: Int = 1_048_576,
        timeout: TimeInterval = 30,
        maximumRedirects: Int = 5,
        classifier: @escaping Classifier = PublicAddressValidator.classify
    ) {
        self.maximumBytes = maximumBytes
        self.timeout = timeout
        self.maximumRedirects = maximumRedirects
        classifyURL = classifier
    }

    func classification(for rawURL: String) async throws -> RestrictedNetworkScope {
        guard let url = URL(string: rawURL) else { throw RestrictedFetchError.invalidURL }
        return try await classifyURL(url)
    }

    func fetch(
        _ rawURL: String,
        method: String,
        headers: [RestrictedHTTPHeader] = [],
        authorizedRestrictedOrigins: Set<String> = [],
        authorizeRestrictedOrigin: @escaping RestrictedOriginAuthorizer = { _, _ in
            throw RestrictedFetchError.authorizationRequired
        }
    ) async throws -> RestrictedHTTPResponse {
        guard let url = URL(string: rawURL) else { throw RestrictedFetchError.invalidURL }
        let checkedHeaders = try RestrictedHTTPHeaderValidator.validate(headers)
        let authorization = RestrictedOriginAuthorization(
            authorizedOrigins: authorizedRestrictedOrigins,
            classifier: classifyURL,
            authorize: authorizeRestrictedOrigin
        )
        try await authorization.authorizeIfNeeded(url)

        let redirectDelegate = RestrictedRedirectDelegate(
            maximumRedirects: maximumRedirects,
            headers: checkedHeaders,
            authorization: authorization
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(
            configuration: configuration, delegate: redirectDelegate, delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
        Self.apply(checkedHeaders, to: &request)
        if !checkedHeaders.contains(where: {
            $0.name.caseInsensitiveCompare("User-Agent") == .orderedSame
        }) {
            request.setValue("Termind/1 Fetch", forHTTPHeaderField: "User-Agent")
        }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw RestrictedFetchError.invalidResponse
        }
        if (300..<400).contains(http.statusCode) {
            if let redirectError = redirectDelegate.redirectError { throw redirectError }
            throw RestrictedFetchError.blockedRedirect
        }

        var data = Data()
        if request.httpMethod != "HEAD" {
            for try await byte in bytes {
                if data.count >= maximumBytes { break }
                data.append(byte)
            }
        }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        let truncated = declaredLength.map { $0 > data.count } ?? (data.count == maximumBytes)
        let responseHeaders: [String: String] = http.allHeaderFields.reduce(into: [:]) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value).prefix(4_096).description
        }
        return RestrictedHTTPResponse(
            url: finalURL, status: http.statusCode, headers: responseHeaders,
            body: String(decoding: data, as: UTF8.self), truncated: truncated
        )
    }

    fileprivate static func apply(_ headers: [RestrictedHTTPHeader], to request: inout URLRequest) {
        let names = Set(headers.map { $0.name.lowercased() })
        for name in names { request.setValue(nil, forHTTPHeaderField: name) }
        for header in headers { request.addValue(header.value, forHTTPHeaderField: header.name) }
    }
}

nonisolated enum RestrictedHTTPHeaderValidator {
    static let maximumCount = 64
    static let maximumNameBytes = 256
    static let maximumValueBytes = 8_192
    static let maximumTotalBytes = 65_536

    private static let forbiddenNames = Set([
        "host", "content-length", "connection", "transfer-encoding", "te", "trailer",
        "upgrade", "proxy-connection",
    ])
    private static let tokenPunctuation = Set("!#$%&'*+-.^_`|~".utf8)

    static func validate(_ headers: [RestrictedHTTPHeader]) throws -> [RestrictedHTTPHeader] {
        guard headers.count <= maximumCount else {
            throw RestrictedFetchError.invalidHeader(
                "At most \(maximumCount) request headers are allowed."
            )
        }
        var total = 0
        for header in headers {
            let nameBytes = Array(header.name.utf8)
            let valueBytes = Array(header.value.utf8)
            guard !nameBytes.isEmpty, nameBytes.count <= maximumNameBytes,
                nameBytes.allSatisfy(isTokenByte)
            else { throw RestrictedFetchError.invalidHeader("The request header name is invalid.") }
            guard valueBytes.count <= maximumValueBytes,
                valueBytes.allSatisfy({ $0 == 0x09 || $0 >= 0x20 && $0 != 0x7F })
            else { throw RestrictedFetchError.invalidHeader("The value for \(header.name) is invalid.") }
            guard !forbiddenNames.contains(header.name.lowercased()), !header.name.hasPrefix(":") else {
                throw RestrictedFetchError.invalidHeader(
                    "\(header.name) is managed by the HTTP transport."
                )
            }
            total += nameBytes.count + valueBytes.count + 4
            guard total <= maximumTotalBytes else {
                throw RestrictedFetchError.invalidHeader("The request headers exceed 64 KiB.")
            }
        }
        return headers
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39 || byte >= 0x41 && byte <= 0x5A
            || byte >= 0x61 && byte <= 0x7A || tokenPunctuation.contains(byte)
    }
}

private actor RestrictedOriginAuthorization {
    private var authorizedOrigins: Set<String>
    private let classifier: RestrictedHTTPFetcher.Classifier
    private let authorize: RestrictedHTTPFetcher.RestrictedOriginAuthorizer

    init(
        authorizedOrigins: Set<String>,
        classifier: @escaping RestrictedHTTPFetcher.Classifier,
        authorize: @escaping RestrictedHTTPFetcher.RestrictedOriginAuthorizer
    ) {
        self.authorizedOrigins = authorizedOrigins
        self.classifier = classifier
        self.authorize = authorize
    }

    func authorizeIfNeeded(_ url: URL) async throws {
        guard try await classifier(url) == .restricted else { return }
        let origin = try PublicAddressValidator.origin(of: url)
        guard !authorizedOrigins.contains(origin) else { return }
        try await authorize(url, origin)
        authorizedOrigins.insert(origin)
    }
}

nonisolated private final class RestrictedRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumRedirects: Int
    private let headers: [RestrictedHTTPHeader]
    private let authorization: RestrictedOriginAuthorization
    private var redirectCount = 0
    private var storedRedirectError: RestrictedFetchError?

    var redirectError: RestrictedFetchError? { lock.withLock { storedRedirectError } }

    init(
        maximumRedirects: Int,
        headers: [RestrictedHTTPHeader],
        authorization: RestrictedOriginAuthorization
    ) {
        self.maximumRedirects = maximumRedirects
        self.headers = headers
        self.authorization = authorization
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let allowed = lock.withLock { () -> Bool in
            redirectCount += 1
            return redirectCount <= maximumRedirects
        }
        guard allowed, let url = request.url else {
            record(.blockedRedirect)
            completionHandler(nil)
            return
        }
        Task {
            do {
                try await authorization.authorizeIfNeeded(url)
                var redirected = request
                RestrictedHTTPFetcher.apply(headers, to: &redirected)
                completionHandler(redirected)
            } catch let error as RestrictedFetchError {
                record(error)
                completionHandler(nil)
            } catch {
                record(.authorizationDenied(error.localizedDescription))
                completionHandler(nil)
            }
        }
    }

    private func record(_ error: RestrictedFetchError) {
        lock.withLock {
            if storedRedirectError == nil { storedRedirectError = error }
        }
    }
}

nonisolated enum PublicAddressValidator {
    static func classify(_ url: URL) async throws -> RestrictedNetworkScope {
        let endpoint = try endpoint(for: url)
        return try await Task.detached(priority: .userInitiated) {
            try resolveAndClassify(host: endpoint.host, port: endpoint.port)
        }.value
    }

    static func origin(of url: URL) throws -> String {
        let endpoint = try endpoint(for: url)
        return "\(endpoint.scheme)|\(endpoint.host.lowercased())|\(endpoint.port)"
    }

    private static func endpoint(for url: URL) throws -> (scheme: String, host: String, port: Int) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.user == nil, url.password == nil,
            let host = url.host, !host.isEmpty
        else { throw RestrictedFetchError.disallowedURL }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { throw RestrictedFetchError.disallowedURL }
        return (scheme, host, port)
    }

    private static func resolveAndClassify(host: String, port: Int) throws -> RestrictedNetworkScope {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil,
            ai_addr: nil, ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let result else {
            throw RestrictedFetchError.dnsFailure
        }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        var found = false
        var scope = RestrictedNetworkScope.publicInternet
        while let entry = cursor {
            guard let address = entry.pointee.ai_addr else {
                cursor = entry.pointee.ai_next
                continue
            }
            found = true
            if entry.pointee.ai_family == AF_INET {
                let socket = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                switch classifyIPv4(UInt32(bigEndian: socket.sin_addr.s_addr)) {
                case .disallowed: throw RestrictedFetchError.disallowedAddress
                case .restricted: scope = .restricted
                case .publicInternet: break
                }
            } else if entry.pointee.ai_family == AF_INET6 {
                let socket = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: socket.sin6_addr) { Array($0) }
                switch classifyIPv6(bytes) {
                case .disallowed: throw RestrictedFetchError.disallowedAddress
                case .restricted: scope = .restricted
                case .publicInternet: break
                }
            }
            cursor = entry.pointee.ai_next
        }
        guard found else { throw RestrictedFetchError.dnsFailure }
        return scope
    }

    private enum AddressClass { case publicInternet, restricted, disallowed }

    private static func classifyIPv4(_ value: UInt32) -> AddressClass {
        func prefix(_ network: UInt32, _ bits: UInt32) -> Bool {
            let mask = bits == 0 ? 0 : UInt32.max << (32 - bits)
            return value & mask == network & mask
        }
        if prefix(0x0000_0000, 8) || prefix(0xE000_0000, 4) || prefix(0xF000_0000, 4) {
            return .disallowed
        }
        if prefix(0x0A00_0000, 8) || prefix(0x6440_0000, 10)
            || prefix(0x7F00_0000, 8) || prefix(0xA9FE_0000, 16)
            || prefix(0xAC10_0000, 12) || prefix(0xC000_0000, 24)
            || prefix(0xC000_0200, 24) || prefix(0xC058_6300, 24)
            || prefix(0xC0A8_0000, 16) || prefix(0xC612_0000, 15)
            || prefix(0xC633_6400, 24) || prefix(0xCB00_7100, 24)
        {
            return .restricted
        }
        return .publicInternet
    }

    private static func classifyIPv6(_ bytes: [UInt8]) -> AddressClass {
        guard bytes.count == 16 else { return .disallowed }
        if bytes.allSatisfy({ $0 == 0 }) || bytes[0] == 0xFF { return .disallowed }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return classifyIPv4(value)
        }
        if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
            || bytes[0] & 0xFE == 0xFC
            || bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80
            || bytes[0] == 0xFE && bytes[1] & 0xC0 == 0xC0
        {
            return .restricted
        }
        guard bytes[0] & 0xE0 == 0x20 else { return .restricted }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return .restricted
        }
        return .publicInternet
    }
}

nonisolated enum RestrictedFetchError: LocalizedError, Sendable {
    case invalidURL, disallowedURL, dnsFailure, disallowedAddress, blockedRedirect, invalidResponse
    case invalidHeader(String)
    case authorizationRequired
    case authorizationDenied(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The fetch URL is invalid."
        case .disallowedURL: "Only credential-free HTTP(S) URLs are allowed."
        case .dnsFailure: "The fetch host could not be resolved."
        case .disallowedAddress:
            "The fetch target resolves to an unspecified, broadcast, or multicast address."
        case .blockedRedirect: "The fetch redirect was blocked."
        case .invalidResponse: "The fetch response was not HTTP."
        case .invalidHeader(let reason): reason
        case .authorizationRequired: "The restricted network target requires authorization."
        case .authorizationDenied(let reason):
            "The restricted network target was not authorized. \(reason)"
        }
    }
}

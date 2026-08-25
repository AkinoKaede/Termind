import Darwin
import Foundation

nonisolated struct RestrictedHTTPResponse: Sendable {
    var url: URL
    var status: Int
    var headers: [String: String]
    var body: String
    var truncated: Bool
}

/// Public-web-only fetcher. Every initial URL and redirect is resolved again
/// immediately before URLSession follows it; local, private and special-use IP
/// ranges are rejected for both address families.
nonisolated struct RestrictedHTTPFetcher: Sendable {
    var maximumBytes = 1_048_576
    var timeout: TimeInterval = 30
    var maximumRedirects = 5

    func fetch(_ rawURL: String, method: String) async throws -> RestrictedHTTPResponse {
        guard let url = URL(string: rawURL) else { throw RestrictedFetchError.invalidURL }
        try await PublicAddressValidator.validate(url)

        let redirectDelegate = RestrictedRedirectDelegate(maximumRedirects: maximumRedirects)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
        request.setValue("Termind/1 Public Fetch", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, let finalURL = http.url else {
            throw RestrictedFetchError.invalidResponse
        }
        try await PublicAddressValidator.validate(finalURL)
        if (300..<400).contains(http.statusCode) { throw RestrictedFetchError.blockedRedirect }

        var data = Data()
        if request.httpMethod != "HEAD" {
            for try await byte in bytes {
                if data.count >= maximumBytes { break }
                data.append(byte)
            }
        }
        let declaredLength = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init)
        let truncated = declaredLength.map { $0 > data.count } ?? (data.count == maximumBytes)
        let headers: [String: String] = http.allHeaderFields.reduce(into: [:]) { result, pair in
            guard let key = pair.key as? String else { return }
            result[key] = String(describing: pair.value).prefix(4_096).description
        }
        return RestrictedHTTPResponse(
            url: finalURL, status: http.statusCode, headers: headers,
            body: String(decoding: data, as: UTF8.self), truncated: truncated
        )
    }
}

nonisolated private final class RestrictedRedirectDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let maximumRedirects: Int
    private var redirectCount = 0

    init(maximumRedirects: Int) { self.maximumRedirects = maximumRedirects }

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
            completionHandler(nil)
            return
        }
        Task {
            do {
                try await PublicAddressValidator.validate(url)
                completionHandler(request)
            } catch { completionHandler(nil) }
        }
    }
}

nonisolated enum PublicAddressValidator {
    static func validate(_ url: URL) async throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            url.user == nil, url.password == nil,
            let host = url.host, !host.isEmpty
        else { throw RestrictedFetchError.disallowedURL }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65_535).contains(port) else { throw RestrictedFetchError.disallowedURL }
        try await Task.detached(priority: .userInitiated) {
            try resolveAndValidate(host: host, port: port)
        }.value
    }

    private static func resolveAndValidate(host: String, port: Int) throws {
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
        while let entry = cursor {
            guard let address = entry.pointee.ai_addr else {
                cursor = entry.pointee.ai_next
                continue
            }
            found = true
            if entry.pointee.ai_family == AF_INET {
                let socket = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                if isBlockedIPv4(UInt32(bigEndian: socket.sin_addr.s_addr)) {
                    throw RestrictedFetchError.privateAddress
                }
            } else if entry.pointee.ai_family == AF_INET6 {
                let socket = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                let bytes = withUnsafeBytes(of: socket.sin6_addr) { Array($0) }
                if isBlockedIPv6(bytes) { throw RestrictedFetchError.privateAddress }
            }
            cursor = entry.pointee.ai_next
        }
        if !found { throw RestrictedFetchError.dnsFailure }
    }

    private static func isBlockedIPv4(_ value: UInt32) -> Bool {
        func prefix(_ network: UInt32, _ bits: UInt32) -> Bool {
            let mask = bits == 0 ? 0 : UInt32.max << (32 - bits)
            return value & mask == network & mask
        }
        return prefix(0x0000_0000, 8) || prefix(0x0A00_0000, 8)
            || prefix(0x6440_0000, 10) || prefix(0x7F00_0000, 8)
            || prefix(0xA9FE_0000, 16) || prefix(0xAC10_0000, 12)
            || prefix(0xC000_0000, 24) || prefix(0xC000_0200, 24)
            || prefix(0xC058_6300, 24) || prefix(0xC0A8_0000, 16)
            || prefix(0xC612_0000, 15)
            || prefix(0xC633_6400, 24) || prefix(0xCB00_7100, 24)
            || prefix(0xE000_0000, 4) || prefix(0xF000_0000, 4)
    }

    private static func isBlockedIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return true }
        if bytes.allSatisfy({ $0 == 0 }) || bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 {
            return true
        }
        // Only globally routable unicast (2000::/3) is eligible. This also
        // excludes site-local, discard-only and other special-purpose ranges.
        if bytes[0] & 0xE0 != 0x20 { return true }
        if bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80)
            || bytes[0] == 0xFF { return true }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 {
            return true
        }
        // IPv4-mapped IPv6 (::ffff:a.b.c.d).
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            let value = bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return isBlockedIPv4(value)
        }
        return false
    }
}

nonisolated enum RestrictedFetchError: LocalizedError, Sendable {
    case invalidURL, disallowedURL, dnsFailure, privateAddress, blockedRedirect, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: "The fetch URL is invalid."
        case .disallowedURL: "Only credential-free public HTTP(S) URLs are allowed."
        case .dnsFailure: "The fetch host could not be resolved."
        case .privateAddress: "The fetch target resolves to a local, private, or special-use address."
        case .blockedRedirect: "The fetch redirect was blocked."
        case .invalidResponse: "The fetch response was not HTTP."
        }
    }
}

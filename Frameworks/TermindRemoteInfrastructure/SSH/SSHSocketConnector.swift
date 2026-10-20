// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import TermindApplication
import TermindDomain

/// Establishes the byte stream libssh2 consumes. Proxy negotiation stays below
/// SSH so host-key verification and authentication are identical for direct and
/// proxied connections.
public nonisolated enum TerminalSocketConnector {
    public static func open(
        host: String, port: Int, proxy: SSHTransportProxy? = nil,
        timeout: TimeInterval = 20
    ) throws -> Int32 {
        defer { proxy?.clearSecret() }
        let socket = try openTCP(
            host: proxy?.hostname ?? host,
            port: proxy?.port ?? port,
            timeout: timeout
        )
        guard let proxy else { return socket }
        do {
            try negotiate(socket: socket, host: host, port: port, proxy: proxy)
            return socket
        } catch {
            Darwin.close(socket)
            throw error
        }
    }

    public static func peerDescription(socket: Int32, fallbackHost: String, port: Int) -> String {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket, $0, &length)
            }
        }
        guard status == 0 else { return displayAddress(host: fallbackHost, port: port) }
        guard
            storage.ss_family == sa_family_t(AF_INET)
                || storage.ss_family == sa_family_t(AF_INET6)
        else { return displayAddress(host: fallbackHost, port: port) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var service = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let lookup = withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo(
                    $0, length, &host, socklen_t(host.count),
                    &service, socklen_t(service.count), NI_NUMERICHOST | NI_NUMERICSERV
                )
            }
        }
        guard lookup == 0 else { return displayAddress(host: fallbackHost, port: port) }
        let hostname = String(
            decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let serviceText = String(
            decoding: service.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let resolvedPort = Int(serviceText) ?? port
        return displayAddress(host: hostname, port: resolvedPort)
    }

    private static func displayAddress(host: String, port: Int) -> String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }

    /// Applies proxy negotiation to an already-open byte stream. Jump routing
    /// uses this with the local end of a socketpair bridged to direct-tcpip.
    public static func negotiate(
        socket: Int32, host: String, port: Int, proxy: SSHTransportProxy
    ) throws {
        defer { proxy.clearSecret() }
        switch proxy.kind {
        case .http:
            try negotiateHTTP(socket: socket, host: host, port: port, proxy: proxy)
        case .socks5:
            try negotiateSOCKS5(socket: socket, host: host, port: port, proxy: proxy)
        }
    }

    private static func negotiateHTTP(
        socket: Int32, host: String, port: Int, proxy: SSHTransportProxy
    ) throws {
        let authority = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        try {
            var request = Data(
                "CONNECT \(authority) HTTP/1.1\r\nHost: \(authority)\r\nProxy-Connection: Keep-Alive\r\n".utf8
            )
            defer { SecretMemory.clear(&request) }
            if let password = proxy.password, !proxy.username.isEmpty {
                var plaintext = Data(proxy.username.utf8)
                plaintext.append(UInt8(ascii: ":"))
                defer { SecretMemory.clear(&plaintext) }
                try password.withUnsafeCStringAndConsume { buffer, count in
                    plaintext.append(
                        buffer.withMemoryRebound(to: UInt8.self, capacity: count) {
                            UnsafeBufferPointer(start: $0, count: count)
                        }
                    )
                }
                var token = plaintext.base64EncodedData()
                defer { SecretMemory.clear(&token) }
                request.append(Data("Proxy-Authorization: Basic ".utf8))
                request.append(token)
                request.append(Data("\r\n".utf8))
            }
            request.append(Data("\r\n".utf8))
            try writeAll(socket, request)
        }()

        var response = Data()
        while response.range(of: Data("\r\n\r\n".utf8)) == nil {
            guard response.count < 64 * 1024 else {
                throw TermindSSHError.proxy("The HTTP proxy response headers are too large.")
            }
            // Stop exactly at the header terminator. A fast proxy may put the
            // SSH banner in the same TCP packet; consuming it here would make
            // the following libssh2 handshake wait for bytes already discarded.
            response.append(try readSome(socket, maximum: 1))
        }
        guard
            let firstLine = String(decoding: response, as: UTF8.self)
                .split(separator: "\n", maxSplits: 1).first
        else { throw TermindSSHError.proxy("The HTTP proxy returned an empty response.") }
        let fields = firstLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]), (200..<300).contains(status) else {
            let status = fields.count >= 2 ? String(fields[1]) : "invalid"
            if status == "407", let hostID = proxy.ownerHostID {
                throw TermindSSHError.proxyAuthentication(
                    hostID: hostID, serverChallenge: true,
                    message: String(localized: "HTTP proxy authentication failed."))
            }
            throw TermindSSHError.proxy("HTTP CONNECT failed with status \(status).")
        }
    }

    private static func negotiateSOCKS5(
        socket: Int32, host: String, port: Int, proxy: SSHTransportProxy
    ) throws {
        let usesAuthentication = proxy.password != nil && !proxy.username.isEmpty
        try writeAll(socket, Data(usesAuthentication ? [0x05, 0x01, 0x02] : [0x05, 0x01, 0x00]))
        let selection = try readExactly(socket, count: 2)
        guard selection[0] == 0x05, selection[1] != 0xff else {
            if let hostID = proxy.ownerHostID {
                throw TermindSSHError.proxyAuthentication(
                    hostID: hostID, serverChallenge: true,
                    message: usesAuthentication
                        ? String(localized: "The SOCKS5 proxy rejected authentication.")
                        : String(localized: "The SOCKS5 proxy requires a password."))
            }
            throw TermindSSHError.proxy("The SOCKS5 proxy does not accept the configured authentication method.")
        }
        if selection[1] == 0x02 {
            guard let password = proxy.password else {
                if let hostID = proxy.ownerHostID {
                    throw TermindSSHError.proxyAuthentication(
                        hostID: hostID, serverChallenge: true,
                        message: String(localized: "The SOCKS5 proxy requires a password."))
                }
                throw TermindSSHError.proxy("The SOCKS5 proxy requires a password.")
            }
            let username = Data(proxy.username.utf8)
            try password.withUnsafeCStringAndConsume { buffer, count in
                guard username.count <= 255, count <= 255 else {
                    throw TermindSSHError.proxy("The SOCKS5 username or password is too long.")
                }
                var auth = Data([0x01, UInt8(username.count)])
                defer { SecretMemory.clear(&auth) }
                auth.append(username)
                auth.append(UInt8(count))
                auth.append(
                    buffer.withMemoryRebound(to: UInt8.self, capacity: count) {
                        UnsafeBufferPointer(start: $0, count: count)
                    }
                )
                try writeAll(socket, auth)
            }
            let result = try readExactly(socket, count: 2)
            guard result[1] == 0 else {
                if let hostID = proxy.ownerHostID {
                    throw TermindSSHError.proxyAuthentication(
                        hostID: hostID, serverChallenge: true,
                        message: String(localized: "SOCKS5 proxy authentication failed."))
                }
                throw TermindSSHError.proxy("SOCKS5 proxy authentication failed.")
            }
        } else if selection[1] != 0x00 {
            throw TermindSSHError.proxy("The SOCKS5 proxy selected an unsupported authentication method.")
        }

        var request = Data([0x05, 0x01, 0x00])
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            request.append(0x01)
            withUnsafeBytes(of: &ipv4) { request.append(contentsOf: $0) }
        } else if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            request.append(0x04)
            withUnsafeBytes(of: &ipv6) { request.append(contentsOf: $0) }
        } else {
            let hostBytes = Data(host.utf8)
            guard hostBytes.count <= 255 else {
                throw TermindSSHError.proxy("The proxy target hostname is too long.")
            }
            request.append(0x03)
            request.append(UInt8(hostBytes.count))
            request.append(hostBytes)
        }
        request.append(UInt8((port >> 8) & 0xff))
        request.append(UInt8(port & 0xff))
        try writeAll(socket, request)

        let response = try readExactly(socket, count: 4)
        guard response[0] == 0x05, response[1] == 0 else {
            throw TermindSSHError.proxy("SOCKS5 CONNECT failed with reply \(response[1]).")
        }
        let addressLength: Int
        switch response[3] {
        case 0x01: addressLength = 4
        case 0x04: addressLength = 16
        case 0x03: addressLength = Int(try readExactly(socket, count: 1)[0])
        default: throw TermindSSHError.proxy("The SOCKS5 proxy returned an invalid address type.")
        }
        _ = try readExactly(socket, count: addressLength + 2)
    }

    private static func openTCP(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else {
            throw TermindSSHError.socket(String(cString: gai_strerror(status)))
        }
        defer { freeaddrinfo(first) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var lastError = String(localized: "Connection failed")
        while let info = cursor?.pointee {
            let candidate = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if candidate >= 0 {
                var yes: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
                var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
                setsockopt(candidate, SOL_SOCKET, SO_RCVTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(candidate, SOL_SOCKET, SO_SNDTIMEO, &interval, socklen_t(MemoryLayout<timeval>.size))
                do {
                    try connect(candidate, address: info.ai_addr, length: info.ai_addrlen, timeout: timeout)
                    return candidate
                } catch { lastError = error.localizedDescription }
                Darwin.close(candidate)
            }
            cursor = info.ai_next
        }
        throw TermindSSHError.socket(lastError)
    }

    private static func connect(
        _ socket: Int32, address: UnsafePointer<sockaddr>, length: socklen_t,
        timeout: TimeInterval
    ) throws {
        let flags = fcntl(socket, F_GETFL, 0)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }
        defer { _ = fcntl(socket, F_SETFL, flags) }
        if Darwin.connect(socket, address, length) == 0 { return }
        guard errno == EINPROGRESS else { throw TermindSSHError.socket(String(cString: strerror(errno))) }
        var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(&descriptor, 1, Int32(max(1, timeout * 1000)))
        guard result > 0 else {
            throw TermindSSHError.socket(
                result == 0 ? String(localized: "Connection timed out.") : String(cString: strerror(errno)))
        }
        var socketError: Int32 = 0
        var errorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) == 0, socketError == 0 else {
            throw TermindSSHError.socket(String(cString: strerror(socketError == 0 ? errno : socketError)))
        }
    }

    private static func writeAll(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.send(socket, base.advanced(by: offset), bytes.count - offset, 0)
                guard written > 0 else { throw TermindSSHError.proxy(String(cString: strerror(errno))) }
                offset += written
            }
        }
    }

    private static func readSome(_ socket: Int32, maximum: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximum)
        let count = Darwin.recv(socket, &buffer, buffer.count, 0)
        guard count > 0 else {
            throw TermindSSHError.proxy(
                count == 0 ? "The proxy closed the connection." : String(cString: strerror(errno)))
        }
        return Data(buffer.prefix(count))
    }

    private static func readExactly(_ socket: Int32, count: Int) throws -> Data {
        var result = Data()
        while result.count < count { result.append(try readSome(socket, maximum: count - result.count)) }
        return result
    }
}

public typealias SSHSocketConnector = TerminalSocketConnector

import Darwin
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct TerminalTCPBridgeTests {
    @Test func boundedBridgePreservesBytesAndTheFinalResponseAfterHalfClose() async throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let peer = pair[1]
        defer { Darwin.close(peer) }
        configure(peer)
        let route = try await routed(pair[0])
        let bridge = try TerminalTCPBridge(open: { throw CancellationError() }, initial: route)
        let client = try connect(to: bridge.port)
        defer { Darwin.close(client) }
        let payload = Data((0..<131_072).map { UInt8($0 % 251) })
        async let received = read(peer, count: payload.count)
        try await write(client, payload)
        #expect(try await received == payload)
        #expect(Darwin.shutdown(client, SHUT_WR) == 0)
        let response = Data("final response after request EOF".utf8)
        try await write(peer, response)
        #expect(Darwin.shutdown(peer, SHUT_WR) == 0)
        #expect(try await read(client, count: response.count) == response)
        await bridge.close()
        #expect(fcntl(route.socket, F_GETFD) == -1)
    }

    @Test func replacementConnectionGetsANewRouteAndCloseReleasesBoth() async throws {
        var first: [Int32] = [-1, -1]
        var second: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
        defer {
            Darwin.close(first[1])
            Darwin.close(second[1])
        }
        configure(first[1])
        configure(second[1])
        let initial = try await routed(first[0])
        let replacement = try await routed(second[0])
        let bridge = try TerminalTCPBridge(open: { replacement }, initial: initial)
        let oldClient = try connect(to: bridge.port)
        try await write(oldClient, Data([1]))
        #expect(try await read(first[1], count: 1) == Data([1]))
        Darwin.close(oldClient)
        let newClient = try connect(to: bridge.port)
        defer { Darwin.close(newClient) }
        try await write(newClient, Data([2]))
        #expect(try await read(second[1], count: 1) == Data([2]))
        await bridge.close()
        #expect(fcntl(initial.socket, F_GETFD) == -1)
        #expect(fcntl(replacement.socket, F_GETFD) == -1)
    }

    private nonisolated func routed(_ socket: Int32) async throws -> SSHRoutedSocket {
        try await SSHRoutedSocket.open(
            host: "routed.invalid", port: 2022, proxy: nil, jumps: [], timeout: 2,
            authorizeHostKey: nil, network: Network(socket: socket))
    }

    private nonisolated struct Network: SSHNetworkDialing {
        let socket: Int32
        func open(host: String, port: Int, timeout: TimeInterval) async throws -> Int32 { socket }
        func hostKeys(stableNodeID: String) async throws -> Set<SSHHostKeyIdentity> { [] }
    }

    private nonisolated func connect(to port: UInt16) throws -> Int32 {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.ENOBUFS) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(socket)
            throw POSIXError(.ECONNREFUSED)
        }
        configure(socket)
        return socket
    }

    private nonisolated func configure(_ socket: Int32) {
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private nonisolated func read(_ socket: Int32, count: Int) async throws -> Data {
        var result = Data()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: min(4096, count - result.count))
            let received = Darwin.recv(socket, &bytes, bytes.count, 0)
            if received > 0 {
                result.append(contentsOf: bytes.prefix(received))
            } else if received == 0 {
                throw POSIXError(.ECONNRESET)
            } else {
                guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                    throw POSIXError(.EIO)
                }
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return result
    }

    private nonisolated func write(_ socket: Int32, _ data: Data) async throws {
        var remaining = data
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !remaining.isEmpty {
            let sent = remaining.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
            if sent > 0 {
                remaining.removeFirst(sent)
            } else {
                guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                    throw POSIXError(.EIO)
                }
                guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}

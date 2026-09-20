import Darwin
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite
struct SSHHandshakeDiagnosticsTests {
    @Test func peerClosingBeforeBannerUsesOneConnectionAndReturnsContext() async throws {
        let server = try BannerServer(behavior: .eof)
        defer { server.close() }
        let hostID = UUID()
        let configuration = SSHConnectionConfiguration(
            hostID: hostID, host: "127.0.0.1", port: server.port,
            username: "deploy", credentials: [.password("test-only")],
            expectedHostKeys: []
        )
        let session = SSHPTYChannel(output: { _ in }, exit: { _ in })

        do {
            try await session.connect(
                using: SSHConnectionRequest(
                    configuration: configuration,
                    authorizeHostKey: { _ in .accept }
                ),
                columns: 80, rows: 24
            )
            Issue.record("Expected the banner handshake to fail")
        } catch let TermindSSHError.handshake(failure) {
            #expect(failure.phase == .identification)
            #expect(failure.code == -13 || failure.code == -43)
            #expect(failure.peer == "127.0.0.1:\(server.port)")
            #expect(failure.elapsedMilliseconds < 5_000)
        }

        #expect(server.acceptedConnections == 1)
    }

    @Test func invalidBannerIsReportedSeparately() async throws {
        let server = try BannerServer(behavior: .invalid)
        defer { server.close() }

        do {
            _ = try await SSHConnectionOpener.openAuthenticatedConnection(
                using: request(for: server), timeout: 2
            )
            Issue.record("Expected the invalid banner to fail")
        } catch let TermindSSHError.handshake(failure) {
            #expect(failure.kind == .invalidIdentification)
            #expect(failure.code == -2)
        }
        #expect(server.acceptedConnections == 1)
    }

    @Test func resetBeforeBannerIsReportedAsAReceiveFailure() async throws {
        let server = try BannerServer(behavior: .reset)
        defer { server.close() }

        do {
            _ = try await SSHConnectionOpener.openAuthenticatedConnection(
                using: request(for: server), timeout: 2
            )
            Issue.record("Expected the reset connection to fail")
        } catch let TermindSSHError.handshake(failure) {
            #expect(failure.kind == .receiveFailed || failure.kind == .peerClosed)
        }
        #expect(server.acceptedConnections == 1)
    }

    @Test func silentPeerIsReportedAsATimeout() async throws {
        let server = try BannerServer(behavior: .stall)
        defer { server.close() }

        do {
            _ = try await SSHConnectionOpener.openAuthenticatedConnection(
                using: request(for: server), timeout: 1
            )
            Issue.record("Expected the silent peer to time out")
        } catch let TermindSSHError.handshake(failure) {
            #expect(failure.kind == .timedOut)
            #expect(failure.elapsedMilliseconds >= 900)
        }
        #expect(server.acceptedConnections == 1)
    }

    @Test func handshakeDiagnosticsRetainThePeerEndpoint() {
        let peer = "203.0.113.4:22"
        let disconnected = SSHHandshakeFailure(
            code: -13, systemError: nil, phase: .identification,
            elapsedMilliseconds: 18, peer: peer
        )
        #expect(disconnected.diagnosticDescription.contains("peer \(peer)"))
    }

    private func request(for server: BannerServer) -> SSHConnectionRequest {
        SSHConnectionRequest(
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: "127.0.0.1", port: server.port,
                username: "deploy", credentials: [.password("test-only")],
                expectedHostKeys: []
            ),
            authorizeHostKey: { _ in .accept }
        )
    }
}

private nonisolated final class BannerServer: @unchecked Sendable {
    enum Behavior: Sendable {
        case eof
        case invalid
        case reset
        case stall
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.akinokaede.termind.tests.banner-eof")
    private var listener: Int32
    private var accepted = 0
    private let behavior: Behavior
    let port: Int

    var acceptedConnections: Int { lock.withLock { accepted } }

    init(behavior: Behavior) throws {
        self.behavior = behavior
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(
            descriptor, SOL_SOCKET, SO_REUSEADDR, &yes,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor, $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EADDRINUSE)
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.EIO)
        }
        listener = descriptor
        port = Int(UInt16(bigEndian: actual.sin_port))
        queue.async { [weak self] in self?.serve(descriptor) }
    }

    func close() {
        guard listener >= 0 else { return }
        Darwin.close(listener)
        listener = -1
    }

    private func serve(_ descriptor: Int32) {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        lock.withLock { accepted += 1 }
        var byte: UInt8 = 0
        while Darwin.recv(client, &byte, 1, 0) == 1, byte != 0x0A {}
        switch behavior {
        case .eof:
            _ = Darwin.shutdown(client, SHUT_RDWR)
        case .invalid:
            var invalid: [UInt8] = [0, 0x0A]
            _ = Darwin.send(client, &invalid, invalid.count, 0)
        case .reset:
            var linger = linger(l_onoff: 1, l_linger: 0)
            setsockopt(
                client, SOL_SOCKET, SO_LINGER, &linger,
                socklen_t(MemoryLayout<Darwin.linger>.size)
            )
        case .stall:
            usleep(1_500_000)
        }
        Darwin.close(client)
    }
}

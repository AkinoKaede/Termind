import Darwin
import Foundation
import TermindApplication
import TermindDomain
import TermindRemoteInfrastructure
import Testing

/// Uses only the loopback fixture from Scripts/ssh-authentication-fixture.py.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil), .serialized)
nonisolated struct SSHForwardingWireTests {
    @Test(arguments: [PortForwardingRule.Kind.local, .remote, .dynamic], [1, 16, 64])
    func concurrentStreamsKeepTheirPayloadsAndHalfClose(_ kind: PortForwardingRule.Kind, _ concurrency: Int)
        async throws
    {
        try await exercise(kind: kind, concurrency: concurrency, jumps: 0)
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .remote, .dynamic], [1, 2])
    func forwardingCrossesJumpBridges(_ kind: PortForwardingRule.Kind, _ jumps: Int) async throws {
        try await exercise(kind: kind, concurrency: 16, jumps: jumps)
    }

    @Test func stoppingOneRulePreservesItsPeerAndReleasesItsListener() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(
            connectionHandler: { _, _ in }, failureHandler: { Issue.record(Comment(rawValue: $0)) })
        try await session.connect(request(fixture, jumps: 0))
        do {
            let first = try rule(.local, fixture: fixture)
            let second = try rule(.local, fixture: fixture)
            try await session.start(first)
            try await session.start(second)
            await session.stop(first.id)
            try await session.start(first)
            try await exchange(port: first.bindPort, target: nil, seed: 1, rounds: 2)
            await session.stop(first.id)
            try await exchange(port: second.bindPort, target: nil, seed: 2, rounds: 2)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_FORWARDING_BENCHMARK"] == "1"),
        arguments: [PortForwardingRule.Kind.local, .remote, .dynamic], [1, 16, 64])
    func sustainedDuplexTransfer(_ kind: PortForwardingRule.Kind, _ concurrency: Int) async throws {
        try await exercise(kind: kind, concurrency: concurrency, jumps: 0, rounds: 128, streaming: true)
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["TERMIND_FORWARDING_BENCHMARK"] == "1"), arguments: [0, 1, 2])
    func smallRequestsProgressBesideBulkStreams(_ jumps: Int) async throws {
        try await exercise(kind: .local, concurrency: 24, jumps: jumps, rounds: 128, mixed: true)
    }

    @Test func slowConsumerPreservesPayloadWhileItsPeerProgresses() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        try await session.connect(request(fixture, jumps: 2))
        do {
            let rule = try rule(.local, fixture: fixture)
            try await session.start(rule)
            async let slow = exchange(
                port: rule.bindPort, target: nil, seed: 41, rounds: 256, streaming: true, delayedRead: true)
            async let small = exchange(port: rule.bindPort, target: nil, seed: 42, rounds: 128, payloadSize: 64)
            let (bulk, peer) = try await (slow, small)
            try #require(bulk.bytes == 257 * 65536)
            try #require(peer.bytes == 129 * 64)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test func disconnectUnderBackpressureReleasesTheListenerAcrossRepeatedStarts() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        let rule = try rule(.local, fixture: fixture)
        for _ in 0..<5 {
            try await session.connect(request(fixture, jumps: 1))
            try await session.start(rule)
            let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: rule.bindPort, timeout: 5)
            let writer = Task {
                await withCheckedContinuation { continuation in
                    Thread.detachNewThread {
                        let payload = Data(repeating: 42, count: 65536)
                        for _ in 0..<1024 {
                            do { try send(socket, payload) } catch { break }
                        }
                        continuation.resume()
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(200))
            let began = ContinuousClock.now
            await session.disconnect()
            try #require(began.duration(to: .now) < .seconds(2))
            _ = Darwin.shutdown(socket, SHUT_RDWR)
            await writer.value
            Darwin.close(socket)
        }
        try await session.connect(request(fixture, jumps: 0))
        try await session.start(rule)
        try await exchange(port: rule.bindPort, target: nil, seed: 1, rounds: 2)
        await session.disconnect()
    }

    @Test func stoppingAnInFlightRemoteListenDrainsItBeforeRebinding() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        try await session.connect(request(fixture, jumps: 0, username: "none-slow-forward"))
        do {
            let rule = try rule(.remote, fixture: fixture)
            let starting = Task { try await session.start(rule) }
            try await Task.sleep(for: .milliseconds(30))
            await session.stop(rule.id)
            do {
                try await starting.value
                Issue.record("Slow listener should have been cancelled while starting")
            } catch is CancellationError {}
            try await session.start(rule)
            try await exchange(port: rule.bindPort, target: nil, seed: 1, rounds: 2)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test func multipleRemoteListenersCanStopAndRestartIndependently() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        try await session.connect(request(fixture, jumps: 1))
        do {
            let first = try rule(.remote, fixture: fixture)
            let second = try rule(.remote, fixture: fixture)
            async let startFirst: Void = session.start(first)
            async let startSecond: Void = session.start(second)
            _ = try await (startFirst, startSecond)
            try await exchange(port: first.bindPort, target: nil, seed: 1, rounds: 2)
            await session.stop(first.id)
            try await exchange(port: second.bindPort, target: nil, seed: 2, rounds: 2)
            try await session.start(first)
            try await exchange(port: first.bindPort, target: nil, seed: 3, rounds: 2)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_FORWARDING_BENCHMARK"] == "1"))
    func idleForwardingCPU() async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(connectionHandler: { _, _ in }, failureHandler: { _ in })
        try await session.connect(request(fixture, jumps: 2))
        let rule = try rule(.local, fixture: fixture)
        try await session.start(rule)
        let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: rule.bindPort, timeout: 5)
        try send(socket, Data([42]))
        try #require(try receive(socket, count: 1) == Data([42]))
        try await Task.sleep(for: .milliseconds(300))
        let before = usage()
        let began = ContinuousClock.now
        try await Task.sleep(for: .seconds(5))
        let elapsed = seconds(began.duration(to: .now))
        let after = usage()
        print("FORWARDING_IDLE cpu_s=\(after.cpu - before.cpu) elapsed_s=\(elapsed) jumps=2")
        Darwin.close(socket)
        await session.disconnect()
    }

    private func exercise(
        kind: PortForwardingRule.Kind, concurrency: Int, jumps: Int,
        rounds: Int = 8, streaming: Bool = false, mixed: Bool = false
    ) async throws {
        let fixture = try fixture()
        let session = SSHForwardingSession(
            connectionHandler: { _, _ in }, failureHandler: { Issue.record(Comment(rawValue: $0)) })
        try await session.connect(request(fixture, jumps: jumps))
        do {
            let rule = try rule(kind, fixture: fixture)
            try await session.start(rule)
            let start = ContinuousClock.now
            let usageBefore = usage()
            let results = try await withThrowingTaskGroup(of: Measurement.self) { group in
                for index in 0..<concurrency {
                    group.addTask {
                        try await exchange(
                            port: rule.bindPort, target: kind == .dynamic ? fixture.echoPort : nil,
                            seed: UInt8(index), rounds: rounds,
                            payloadSize: mixed && index >= 8 ? 64 : 65536,
                            streaming: streaming || (mixed && index < 8))
                    }
                }
                var results: [Measurement] = []
                for try await result in group { results.append(result) }
                return results
            }
            let elapsed = seconds(start.duration(to: .now))
            let usageAfter = usage()
            let payloadBytes = results.reduce(0) { $0 + $1.bytes }
            let record: [String: Any] = [
                "kind": kind.rawValue, "streams": concurrency, "jumps": jumps,
                "workload": mixed ? "mixed" : streaming ? "duplex" : "request_response",
                "successful_streams": results.count, "payload_bytes_per_direction": payloadBytes,
                "elapsed_s": elapsed, "payload_mib_s_per_direction": Double(payloadBytes) / 1_048_576 / elapsed,
                "ready_p95_ms": percentile(results.map(\.connect)) * 1000,
                "request_p95_ms": percentile(results.filter { !$0.streaming }.flatMap(\.latencies)) * 1000,
                "small_request_p95_ms": percentile(results.filter { $0.small }.flatMap(\.latencies)) * 1000,
                "cpu_s": usageAfter.cpu - usageBefore.cpu,
                "process_peak_rss_mib": Double(usageAfter.rss) / 1_048_576,
            ]
            print(
                "FORWARDING_METRIC "
                    + String(
                        decoding: try JSONSerialization.data(
                            withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
            await session.stop(rule.id)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    private struct Fixture: Decodable {
        let port: Int
        let echoPort: Int
    }

    private func fixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func request(_ fixture: Fixture, jumps: Int, username: String = "none") -> SSHConnectionRequest {
        var configuration = SSHConnectionConfiguration(
            hostID: UUID(), host: "127.0.0.1", port: fixture.port, username: username, credentials: [],
            expectedHostKeys: [])
        configuration.jumps = (0..<jumps).map { _ in
            SSHRouteHopConfiguration(
                id: UUID(), name: "Fixture", host: "127.0.0.1", port: fixture.port, username: "none",
                credentials: [], expectedHostKeys: [])
        }
        return SSHConnectionRequest(configuration: configuration, authorizeHostKey: { _ in .accept })
    }

    private func rule(_ kind: PortForwardingRule.Kind, fixture: Fixture) throws -> PortForwardingRule {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0 else { throw POSIXError(.EIO) }
        return PortForwardingRule(
            hostID: UUID(), kind: kind, bindHost: "127.0.0.1", bindPort: Int(UInt16(bigEndian: address.sin_port)),
            targetHost: "127.0.0.1", targetPort: fixture.echoPort)
    }

    private struct Measurement: Sendable {
        let connect: Double
        let latencies: [Double]
        let bytes: Int
        let streaming: Bool
        let small: Bool
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func percentile(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private func usage() -> (cpu: Double, rss: Int) {
        var value = rusage()
        getrusage(RUSAGE_SELF, &value)
        let cpu =
            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1e6
        return (cpu, value.ru_maxrss)
    }

    @discardableResult private func exchange(
        port: Int, target: Int?, seed: UInt8, rounds: Int, payloadSize: Int = 65536, streaming: Bool = false,
        delayedRead: Bool = false
    ) async throws -> Measurement {
        // Dedicated test-client threads cannot exhaust the dispatch worker pool
        // needed by the transport and its bounded DNS resolver.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Measurement, any Error>) in
            Thread.detachNewThread {
                do {
                    let began = ContinuousClock.now
                    let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: port, timeout: 15)
                    defer { Darwin.close(socket) }
                    if let target {
                        // A fragmented greeting followed by CONNECT + payload in
                        // one write exercises both parser boundaries.
                        try send(socket, Data([5]))
                        try send(socket, Data([1, 0]))
                        try #require(try receive(socket, count: 2) == Data([5, 0]))
                        let request = Data([5, 1, 0, 1, 127, 0, 0, 1, UInt8(target >> 8), UInt8(target & 255)])
                        try send(socket, request + Data([seed]))
                        try #require(try receive(socket, count: 10) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
                        try #require(try receive(socket, count: 1) == Data([seed]))
                    }
                    // Include channel negotiation and target connect for every
                    // forwarding kind, rather than just the local TCP accept.
                    try send(socket, Data([seed]))
                    try #require(try receive(socket, count: 1) == Data([seed]))
                    let connected = seconds(began.duration(to: .now))
                    let payload = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0) &+ seed })
                    var latencies: [Double] = []
                    if streaming {
                        // Independent producer and consumer exercise sustained
                        // full-duplex forwarding beyond both SSH/socket windows.
                        let producer = DispatchGroup()
                        producer.enter()
                        Thread.detachNewThread {
                            defer { producer.leave() }
                            do {
                                for _ in 0...rounds { try send(socket, payload) }
                            } catch { Issue.record(error) }
                            _ = Darwin.shutdown(socket, SHUT_WR)
                        }
                        defer {
                            _ = Darwin.shutdown(socket, SHUT_RDWR)
                            producer.wait()
                        }
                        if delayedRead { Thread.sleep(forTimeInterval: 0.3) }
                        for _ in 0...rounds {
                            try #require(try receive(socket, count: payload.count) == payload)
                        }
                        var byte: UInt8 = 0
                        try #require(Darwin.recv(socket, &byte, 1, 0) == 0)
                    } else {
                        for _ in 0..<rounds {
                            let sent = ContinuousClock.now
                            try send(socket, payload)
                            try #require(try receive(socket, count: payload.count) == payload)
                            latencies.append(seconds(sent.duration(to: .now)))
                        }
                        // The response is still pending when the client sends FIN.
                        try send(socket, payload)
                        _ = Darwin.shutdown(socket, SHUT_WR)
                        try #require(try receive(socket, count: payload.count) == payload)
                    }
                    if !streaming {
                        var byte: UInt8 = 0
                        try #require(Darwin.recv(socket, &byte, 1, 0) == 0)
                    }
                    continuation.resume(
                        returning: Measurement(
                            connect: connected, latencies: latencies, bytes: (rounds + 1) * payloadSize,
                            streaming: streaming, small: payloadSize == 64))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func send(_ socket: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.send(socket, bytes.baseAddress! + offset, bytes.count - offset, 0)
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                offset += count
            }
        }
    }

    private func receive(_ socket: Int32, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let read = Darwin.recv(socket, bytes.baseAddress! + offset, count - offset, 0)
                guard read > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += read
            }
        }
        return data
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import TermindApplication
import TermindDomain
@_spi(PortForwardingBenchmark) import TermindRemoteInfrastructure

@main
enum PortForwardingBenchmark {
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments.dropFirst())
            let fixture = try JSONDecoder().decode(
                Fixture.self,
                from: Data(contentsOf: URL(fileURLWithPath: arguments.metadataPath)))
            let runner = BenchmarkRunner(fixture: fixture, maximumConnections: arguments.maximumConnections)
            try await runner.run()
        } catch {
            FileHandle.standardError.write(Data("termind-port-forwarding-benchmark: \(error)\n".utf8))
            Darwin.exit(EXIT_FAILURE)
        }
    }
}

private struct Arguments {
    let metadataPath: String
    let maximumConnections: Int

    static func parse(_ rawArguments: ArraySlice<String>) throws -> Arguments {
        var metadataPath: String?
        var maximumConnections = 1
        var index = rawArguments.startIndex
        while index < rawArguments.endIndex {
            let argument = rawArguments[index]
            index = rawArguments.index(after: index)
            switch argument {
            case "--metadata":
                guard index < rawArguments.endIndex else { throw BenchmarkError.missingValue(argument) }
                metadataPath = rawArguments[index]
                index = rawArguments.index(after: index)
            case "--max-connections":
                guard index < rawArguments.endIndex else { throw BenchmarkError.missingValue(argument) }
                guard let value = Int(rawArguments[index]), Host.portForwardingMaxConnectionsRange.contains(value)
                else {
                    throw BenchmarkError.invalidConnections(rawArguments[index])
                }
                maximumConnections = value
                index = rawArguments.index(after: index)
            case "--help", "-h":
                print(
                    "Usage: termind-port-forwarding-benchmark --metadata PATH "
                        + "[--max-connections 1...64]")
                Darwin.exit(EXIT_SUCCESS)
            default:
                throw BenchmarkError.unknownArgument(argument)
            }
        }
        guard let metadataPath else { throw BenchmarkError.missingValue("--metadata") }
        return Arguments(metadataPath: metadataPath, maximumConnections: maximumConnections)
    }
}

private struct Fixture: Decodable, Sendable {
    let port: Int
    let echoPort: Int
    let server: String?
    let username: String?
    let privateKey: String?
    let hostKeyFingerprint: String?
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case invalidConnections(String)
    case invalidPayload
    case missingValue(String)
    case poolDidNotWarm(connected: Int, target: Int, failure: String?)
    case socket(String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .invalidConnections(let value):
            "invalid connection count '\(value)'; expected 1...64"
        case .invalidPayload:
            "forwarding changed or truncated the payload"
        case .missingValue(let argument):
            "missing value for \(argument)"
        case .poolDidNotWarm(let connected, let target, let failure):
            "connection pool reached \(connected)/\(target) before timeout"
                + (failure.map { ": \($0)" } ?? "")
        case .socket(let message):
            message
        case .unknownArgument(let argument):
            "unknown argument \(argument)"
        }
    }
}

private final class FailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessage: String?

    var message: String? { lock.withLock { storedMessage } }

    func record(_ message: String) {
        lock.withLock { storedMessage = message }
    }
}

private final class SendFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: (any Error)?

    var error: (any Error)? { lock.withLock { storedError } }

    func record(_ error: any Error) {
        lock.withLock { storedError = error }
    }
}

private struct Measurement: Sendable {
    let connect: Double
    let latencies: [Double]
    let bytes: Int
    let streaming: Bool
    let small: Bool
}

private struct BenchmarkRunner {
    let fixture: Fixture
    let maximumConnections: Int

    func run() async throws {
        let kinds: [PortForwardingRule.Kind] = [.local, .remote, .dynamic]
        for kind in kinds {
            for concurrency in [1, 16, 64] {
                try await exercise(kind: kind, concurrency: concurrency, jumps: 0, rounds: 8)
            }
        }
        for kind in kinds {
            for jumps in [1, 2] {
                try await exercise(kind: kind, concurrency: 16, jumps: jumps, rounds: 8)
            }
        }
        for kind in kinds {
            for concurrency in [1, 16, 64] {
                try await exercise(
                    kind: kind, concurrency: concurrency, jumps: 0, rounds: 128, streaming: true)
            }
        }
        for jumps in [0, 1, 2] {
            try await exercise(kind: .local, concurrency: 24, jumps: jumps, rounds: 128, mixed: true)
        }
        try await measureIdleCPU()
    }

    private func exercise(
        kind: PortForwardingRule.Kind, concurrency: Int, jumps: Int,
        rounds: Int, streaming: Bool = false, mixed: Bool = false
    ) async throws {
        let effectiveMaximum = kind == .remote ? 1 : maximumConnections
        let failures = FailureRecorder()
        let session = SSHForwardingBenchmarkAccess.makeSession(
            maximumConnections: effectiveMaximum,
            failureHandler: { failures.record($0) })
        let connectionRequest = request(jumps: jumps)
        try await session.connect(connectionRequest, progress: nil)
        if effectiveMaximum > 1 {
            await session.configureAdditionalConnections {
                var request = self.request(jumps: jumps)
                request.interactionPolicy = .forbidden
                return request.enforcingInteractionPolicy()
            }
        }
        do {
            let rule = try rule(kind)
            try await session.start(rule, generation: UUID())
            try await waitForPool(session, target: effectiveMaximum, failures: failures)
            let start = ContinuousClock.now
            let usageBefore = usage()
            let results = try await withThrowingTaskGroup(of: Measurement.self) { group in
                for index in 0..<concurrency {
                    group.addTask {
                        try await exchange(
                            port: rule.bindPort,
                            target: kind == .dynamic ? fixture.echoPort : nil,
                            seed: UInt8(truncatingIfNeeded: index),
                            rounds: rounds,
                            payloadSize: mixed && index >= 8 ? 64 : 65_536,
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
            var record: [String: Any] = [
                "kind": kind.rawValue,
                "streams": concurrency,
                "jumps": jumps,
                "workload": mixed ? "mixed" : streaming ? "duplex" : "request_response",
                "successful_streams": results.count,
                "payload_bytes_per_direction": payloadBytes,
                "elapsed_s": elapsed,
                "payload_mib_s_per_direction": Double(payloadBytes) / 1_048_576 / elapsed,
                "ready_p95_ms": percentile(results.map(\.connect)) * 1_000,
                "request_p95_ms": percentile(results.filter { !$0.streaming }.flatMap(\.latencies)) * 1_000,
                "small_request_p95_ms": percentile(results.filter(\.small).flatMap(\.latencies)) * 1_000,
                "cpu_s": usageAfter.cpu - usageBefore.cpu,
                "process_peak_rss_mib": Double(usageAfter.rss) / 1_048_576,
            ]
            record["ssh_connections"] = await session.connectionPoolStatus().connected
            if let statistics = await SSHForwardingBenchmarkAccess.statistics(for: session) {
                record["pump_passes"] = statistics.pumpPasses
                record["plaintext_socket_write_calls"] = statistics.plaintextSocketWriteCalls
                record["encrypted_socket_write_calls"] = statistics.encryptedSocketWriteCalls
                record["peak_plaintext_queue_bytes"] = statistics.peakPlaintextQueueBytes
                record["peak_encrypted_queue_bytes"] = statistics.peakEncryptedQueueBytes
            }
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("FORWARDING_METRIC " + String(decoding: data, as: UTF8.self))
            await session.stop(rule.id)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    private func waitForPool(
        _ session: any SSHForwardingConnectionProtocol,
        target: Int,
        failures: FailureRecorder
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline {
            if await session.connectionPoolStatus().connected == target { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let status = await session.connectionPoolStatus()
        throw BenchmarkError.poolDidNotWarm(
            connected: status.connected, target: target, failure: failures.message)
    }

    private func measureIdleCPU() async throws {
        let failures = FailureRecorder()
        let session = SSHForwardingBenchmarkAccess.makeSession(
            maximumConnections: 1,
            failureHandler: { failures.record($0) })
        try await session.connect(request(jumps: 2), progress: nil)
        let forwardingRule = try rule(.local)
        try await session.start(forwardingRule, generation: UUID())
        let socket = try SSHSocketConnector.open(
            host: "127.0.0.1", port: forwardingRule.bindPort, timeout: 5)
        defer { Darwin.close(socket) }
        try send(socket, Data([42]))
        guard try receive(socket, count: 1) == Data([42]) else { throw BenchmarkError.invalidPayload }
        try await Task.sleep(for: .milliseconds(300))
        let before = usage()
        let began = ContinuousClock.now
        try await Task.sleep(for: .seconds(5))
        let elapsed = seconds(began.duration(to: .now))
        let after = usage()
        print("FORWARDING_IDLE cpu_s=\(after.cpu - before.cpu) elapsed_s=\(elapsed) jumps=2")
        await session.disconnect()
    }

    private func request(jumps: Int) -> SSHConnectionRequest {
        let username = fixture.username ?? "none"
        func credentials() -> [SSHCredentials] {
            fixture.username.flatMap { _ in fixture.privateKey }.map {
                [.privateKey(privateKey: $0, publicKey: nil, passphrase: nil)]
            } ?? []
        }
        let expectedHostKeys: Set<SSHHostKeyIdentity> =
            fixture.hostKeyFingerprint.map {
                [SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: $0)]
            } ?? []
        var configuration = SSHConnectionConfiguration(
            hostID: UUID(),
            host: "127.0.0.1",
            port: fixture.port,
            username: username,
            credentials: credentials(),
            expectedHostKeys: expectedHostKeys)
        configuration.jumps = (0..<jumps).map { _ in
            SSHRouteHopConfiguration(
                id: UUID(),
                name: "Fixture",
                host: "127.0.0.1",
                port: fixture.port,
                username: username,
                credentials: credentials(),
                expectedHostKeys: expectedHostKeys)
        }
        return SSHConnectionRequest(configuration: configuration, authorizeHostKey: { _ in .accept })
    }

    private func rule(_ kind: PortForwardingRule.Kind) throws -> PortForwardingRule {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw posixError() }
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
        guard result == 0 else { throw posixError() }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0 else { throw posixError() }
        return PortForwardingRule(
            hostID: UUID(),
            kind: kind,
            bindHost: "127.0.0.1",
            bindPort: Int(UInt16(bigEndian: address.sin_port)),
            targetHost: "127.0.0.1",
            targetPort: fixture.echoPort)
    }
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

private func exchange(
    port: Int,
    target: Int?,
    seed: UInt8,
    rounds: Int,
    payloadSize: Int,
    streaming: Bool
) async throws -> Measurement {
    try await withCheckedThrowingContinuation { continuation in
        Thread.detachNewThread {
            do {
                let began = ContinuousClock.now
                let socket = try SSHSocketConnector.open(host: "127.0.0.1", port: port, timeout: 15)
                defer { Darwin.close(socket) }
                if let target {
                    try send(socket, Data([5]))
                    try send(socket, Data([1, 0]))
                    guard try receive(socket, count: 2) == Data([5, 0]) else {
                        throw BenchmarkError.invalidPayload
                    }
                    let request = Data([5, 1, 0, 1, 127, 0, 0, 1, UInt8(target >> 8), UInt8(target & 255)])
                    try send(socket, request + Data([seed]))
                    guard try receive(socket, count: 10) == Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]),
                        try receive(socket, count: 1) == Data([seed])
                    else { throw BenchmarkError.invalidPayload }
                }
                try send(socket, Data([seed]))
                guard try receive(socket, count: 1) == Data([seed]) else {
                    throw BenchmarkError.invalidPayload
                }
                let connected = seconds(began.duration(to: .now))
                let payload = Data((0..<payloadSize).map { UInt8(truncatingIfNeeded: $0) &+ seed })
                var latencies: [Double] = []
                if streaming {
                    let producer = DispatchGroup()
                    let sendFailure = SendFailure()
                    producer.enter()
                    Thread.detachNewThread {
                        defer { producer.leave() }
                        do {
                            for _ in 0...rounds { try send(socket, payload) }
                            _ = Darwin.shutdown(socket, SHUT_WR)
                        } catch {
                            sendFailure.record(error)
                            _ = Darwin.shutdown(socket, SHUT_RDWR)
                        }
                    }
                    defer {
                        _ = Darwin.shutdown(socket, SHUT_RDWR)
                        producer.wait()
                    }
                    for _ in 0...rounds {
                        guard try receive(socket, count: payload.count) == payload else {
                            throw BenchmarkError.invalidPayload
                        }
                    }
                    var byte: UInt8 = 0
                    guard Darwin.recv(socket, &byte, 1, 0) == 0 else { throw posixError() }
                    producer.wait()
                    if let error = sendFailure.error { throw error }
                } else {
                    for _ in 0..<rounds {
                        let sent = ContinuousClock.now
                        try send(socket, payload)
                        guard try receive(socket, count: payload.count) == payload else {
                            throw BenchmarkError.invalidPayload
                        }
                        latencies.append(seconds(sent.duration(to: .now)))
                    }
                    try send(socket, payload)
                    _ = Darwin.shutdown(socket, SHUT_WR)
                    guard try receive(socket, count: payload.count) == payload else {
                        throw BenchmarkError.invalidPayload
                    }
                    var byte: UInt8 = 0
                    guard Darwin.recv(socket, &byte, 1, 0) == 0 else { throw posixError() }
                }
                continuation.resume(
                    returning: Measurement(
                        connect: connected,
                        latencies: latencies,
                        bytes: (rounds + 1) * payloadSize,
                        streaming: streaming,
                        small: payloadSize == 64))
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

private func send(_ socket: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.send(socket, bytes.baseAddress! + offset, bytes.count - offset, 0)
            guard count > 0 else { throw posixError() }
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
            guard read > 0 else { throw posixError() }
            offset += read
        }
    }
    return data
}

private func posixError() -> BenchmarkError {
    let code = POSIXErrorCode(rawValue: errno) ?? .EIO
    return .socket(String(cString: strerror(code.rawValue)))
}

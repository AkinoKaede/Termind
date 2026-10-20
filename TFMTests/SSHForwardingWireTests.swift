// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import TermindApplication
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

/// Uses the loopback Paramiko or forwarding-only OpenSSH fixture in Scripts/.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"] != nil), .serialized)
nonisolated struct SSHForwardingWireTests {
    @Test func losingRetainedAuxiliaryRestoresAdmissionWhileOtherConnectionsDrain() async throws {
        let fixture = try fixture()
        let connections = ForwardingWireConnections()
        let pool = SSHForwardingConnectionPool(
            maximumConnections: 4, connectionHandler: { _, _, _ in },
            failureHandler: { Issue.record(Comment(rawValue: $0)) },
            makeConnection: { id, connectionHandler, failureHandler in
                connections.make(id: id, connectionHandler: connectionHandler, failureHandler: failureHandler)
            })
        try await pool.connect(request(fixture, jumps: 0), progress: nil)
        defer { Task { await pool.disconnect() } }
        await pool.configureAdditionalConnections { request(fixture, jumps: 0).enforcingInteractionPolicy() }
        let existingRule = try rule(.local, fixture: fixture)
        try await pool.start(existingRule, generation: UUID())
        try await waitForPool(pool, connected: 4, target: 4)

        var clients: [Int32] = []
        defer { for client in clients { Darwin.close(client) } }
        for _ in 0..<16 {
            clients.append(try SSHSocketConnector.open(host: "127.0.0.1", port: existingRule.bindPort))
        }
        try await waitForFlows(pool, ruleID: existingRule.id, count: 16, connections: 4)
        await pool.updateMaximumConnections(2)
        // The primary is created first; the pool retains auxiliaries in UUID order.
        let retained = try #require(
            connections.entries.dropFirst().min { $0.id.uuidString < $1.id.uuidString })
        await retained.connection.disconnect()
        // Graceful disconnect does not emit failure. Inject the event after closing
        // the real transport to exercise pool recovery, not network-loss detection.
        retained.failureHandler("Retained auxiliary disconnected by the wire fixture")
        try await waitForPool(pool, connected: 3, target: 2)

        let newRule = try rule(.local, fixture: fixture)
        try await pool.start(newRule, generation: UUID())
        for _ in 0..<12 {
            clients.append(try SSHSocketConnector.open(host: "127.0.0.1", port: newRule.bindPort))
        }
        try await waitForFlows(pool, ruleID: newRule.id, count: 12, connections: 2)
        for client in clients.suffix(12) {
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            try send(client, Data([42]))
            #expect(try receive(client, count: 1) == Data([42]))
        }
        #expect(await pool.connectionPoolStatus() == SSHForwardingPoolStatus(connected: 3, target: 2))
    }

    private func waitForFlows(
        _ pool: SSHForwardingConnectionPool, ruleID: UUID, count: Int, connections: Int
    ) async throws {
        for _ in 0..<1_000 {
            let distribution = await pool.flowDistribution(for: ruleID)
            if distribution.reduce(0, +) == count, distribution.filter({ $0 > 0 }).count == connections { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        let distribution = await pool.flowDistribution(for: ruleID)
        try #require(distribution.reduce(0, +) == count)
        try #require(distribution.filter { $0 > 0 }.count == connections)
    }

    @Test func poolShrinksWithoutClosingExistingFlowsAndCanExpandAgain() async throws {
        let fixture = try fixture()
        let pool = SSHForwardingConnectionPool(
            maximumConnections: 1, connectionHandler: { _, _, _ in },
            failureHandler: { Issue.record(Comment(rawValue: $0)) })
        try await pool.connect(request(fixture, jumps: 0), progress: nil)
        await pool.configureAdditionalConnections { request(fixture, jumps: 0).enforcingInteractionPolicy() }
        let local = try rule(.local, fixture: fixture)
        try await pool.start(local, generation: UUID())
        defer { Task { await pool.disconnect() } }
        #expect(await pool.connectionPoolStatus() == .single)
        await pool.updateMaximumConnections(3)
        try await waitForPool(pool, connected: 3, target: 3)
        var clients: [Int32] = []
        defer { for client in clients { Darwin.close(client) } }
        for _ in 0..<12 { clients.append(try SSHSocketConnector.open(host: "127.0.0.1", port: local.bindPort)) }
        for _ in 0..<1_000 {
            if await pool.flowDistribution(for: local.id).reduce(0, +) == clients.count { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await pool.flowDistribution(for: local.id).filter { $0 > 0 }.count > 1)
        await pool.updateMaximumConnections(1)
        #expect(await pool.connectionPoolStatus().target == 1)
        // Every established TCP stream must still pass data after the downgrade.
        for client in clients {
            var sent: UInt8 = 42
            #expect(Darwin.write(client, &sent, 1) == 1)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var received: UInt8 = 0
            #expect(Darwin.read(client, &received, 1) == 1)
            #expect(received == sent)
        }
        // A new stream still works on the retained connection while auxiliaries drain.
        try await exchange(port: local.bindPort, target: nil, seed: 72, rounds: 2)
        let addedWhileDraining = try rule(.local, fixture: fixture)
        try await pool.start(addedWhileDraining, generation: UUID())
        await pool.updateMaximumConnections(3)
        try await waitForPool(pool, connected: 3, target: 3)
        var addedClients: [Int32] = []
        defer { for client in addedClients { Darwin.close(client) } }
        for _ in 0..<12 {
            addedClients.append(try SSHSocketConnector.open(host: "127.0.0.1", port: addedWhileDraining.bindPort))
        }
        for _ in 0..<1_000 {
            if await pool.flowDistribution(for: addedWhileDraining.id).filter({ $0 > 0 }).count > 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await pool.flowDistribution(for: addedWhileDraining.id).filter { $0 > 0 }.count > 1)
        for client in addedClients { Darwin.close(client) }
        addedClients.removeAll()
        await pool.updateMaximumConnections(1)
        for client in clients { Darwin.close(client) }
        clients.removeAll()
        try await waitForPool(pool, connected: 1, target: 1)
        await pool.updateMaximumConnections(3)
        try await waitForPool(pool, connected: 3, target: 3)
        await pool.updateMaximumConnections(1)
        try await waitForPool(pool, connected: 1, target: 1)
    }

    private func waitForPool(_ pool: SSHForwardingConnectionPool, connected: Int, target: Int) async throws {
        let expected = SSHForwardingPoolStatus(connected: connected, target: target)
        for _ in 0..<1_000 {
            if await pool.connectionPoolStatus() == expected { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await pool.connectionPoolStatus() == expected)
    }

    @Test(arguments: [PortForwardingRule.Kind.local, .dynamic])
    func disconnectReleasesThePortBeforeReturningEvenWithEstablishedStreams(_ kind: PortForwardingRule.Kind)
        async throws
    {
        let fixture = try fixture()
        let rule = try rule(kind, fixture: fixture)
        for _ in 0..<5 {
            let count = ForwardingWireConnectionCount()
            let session = SSHForwardingConnection(
                connectionHandler: { _, _, value in count.set(value) }, failureHandler: { _ in })
            try await session.connect(request(fixture, jumps: 0))
            do {
                try await session.start(rule)
                var duplicate = rule
                duplicate.id = UUID()
                await #expect(throws: TermindSSHError.self) { try await session.start(duplicate) }
                let client = try SSHSocketConnector.open(host: "127.0.0.1", port: rule.bindPort, timeout: 5)
                defer { Darwin.close(client) }
                for _ in 0..<1000 where count.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
                try #require(count.value == 1)
                // Close the server side first so its accepted stream can enter TIME_WAIT.
                await session.disconnect()
                _ = Darwin.shutdown(client, SHUT_RDWR)

                let candidate = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                try #require(candidate >= 0)
                defer { Darwin.close(candidate) }
                var yes: Int32 = 1
                try #require(
                    setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                address.sin_port = UInt16(rule.bindPort).bigEndian
                let bound = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(candidate, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                try #require(bound == 0, "The previous forwarding listener must have released its port")
                try #require(Darwin.listen(candidate, 1) == 0)
            } catch {
                await session.disconnect()
                throw error
            }
        }
    }

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
        let session = SSHForwardingConnection(
            connectionHandler: { _, _, _ in }, failureHandler: { Issue.record(Comment(rawValue: $0)) })
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

    @Test func slowConsumerPreservesPayloadWhileItsPeerProgresses() async throws {
        let fixture = try fixture()
        let session = SSHForwardingConnection(connectionHandler: { _, _, _ in }, failureHandler: { _ in })
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

    @Test func localPoolDistributesAcceptedFlowsAcrossPhysicalConnections() async throws {
        let fixture = try fixture()
        let fingerprint = try #require(fixture.hostKeyFingerprint)
        let pool = SSHForwardingConnectionPool(
            maximumConnections: 4, connectionHandler: { _, _, _ in },
            failureHandler: { Issue.record(Comment(rawValue: $0)) })
        var primary = request(fixture, jumps: 0)
        primary.configuration.expectedHostKeys = [
            SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: fingerprint)
        ]
        primary.authorizeHostKey = nil
        try await pool.connect(primary, progress: nil)
        await pool.configureAdditionalConnections {
            var additional = request(fixture, jumps: 0)
            additional.configuration.expectedHostKeys = [
                SSHHostKeyIdentity(algorithm: .ed25519, fingerprint: fingerprint)
            ]
            additional.interactionPolicy = .forbidden
            return additional.enforcingInteractionPolicy()
        }
        let local = try rule(.local, fixture: fixture)
        try await pool.start(local, generation: UUID())
        defer { Task { await pool.disconnect() } }
        for _ in 0..<1_000 {
            if await pool.connectionPoolStatus().connected == 4 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await pool.connectionPoolStatus() == SSHForwardingPoolStatus(connected: 4, target: 4))
        try await Task.sleep(for: .milliseconds(200))
        #expect(await pool.connectionPoolStatus() == SSHForwardingPoolStatus(connected: 4, target: 4))

        var clients: [Int32] = []
        for _ in 0..<12 { clients.append(try SSHSocketConnector.open(host: "127.0.0.1", port: local.bindPort)) }
        defer { for client in clients { Darwin.close(client) } }
        for _ in 0..<1_000 {
            if await pool.flowDistribution(for: local.id).filter({ $0 > 0 }).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await pool.flowDistribution(for: local.id).filter { $0 > 0 }.count >= 2)
    }

    @Test func disconnectUnderBackpressureReleasesTheListenerAcrossRepeatedStarts() async throws {
        let fixture = try fixture()
        let session = SSHForwardingConnection(connectionHandler: { _, _, _ in }, failureHandler: { _ in })
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
        // Only Paramiko provides the deliberately delayed listener reply.
        guard fixture.server != "openssh" else { return }
        let session = SSHForwardingConnection(connectionHandler: { _, _, _ in }, failureHandler: { _ in })
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
        let session = SSHForwardingConnection(connectionHandler: { _, _, _ in }, failureHandler: { _ in })
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

    private func exercise(
        kind: PortForwardingRule.Kind, concurrency: Int, jumps: Int, rounds: Int = 8
    ) async throws {
        let fixture = try fixture()
        let session = SSHForwardingConnection(
            connectionHandler: { _, _, _ in },
            failureHandler: { Issue.record(Comment(rawValue: $0)) })
        try await session.connect(request(fixture, jumps: jumps), progress: nil)
        do {
            let rule = try rule(kind, fixture: fixture)
            try await session.start(rule, generation: UUID())
            _ = try await withThrowingTaskGroup(of: Measurement.self) { group in
                for index in 0..<concurrency {
                    group.addTask {
                        try await exchange(
                            port: rule.bindPort, target: kind == .dynamic ? fixture.echoPort : nil,
                            seed: UInt8(index), rounds: rounds)
                    }
                }
                var results: [Measurement] = []
                for try await result in group { results.append(result) }
                return results
            }
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
        let server: String?
        let username: String?
        let privateKey: String?
        let hostKeyFingerprint: String?
    }

    private func fixture() throws -> Fixture {
        let path = try #require(ProcessInfo.processInfo.environment["TERMIND_SSH_FIXTURE"])
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func request(_ fixture: Fixture, jumps: Int, username: String = "none") -> SSHConnectionRequest {
        let user = fixture.username ?? username
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
            hostID: UUID(), host: "127.0.0.1", port: fixture.port, username: user, credentials: credentials(),
            expectedHostKeys: expectedHostKeys)
        configuration.jumps = (0..<jumps).map { _ in
            SSHRouteHopConfiguration(
                id: UUID(), name: "Fixture", host: "127.0.0.1", port: fixture.port, username: user,
                credentials: credentials(), expectedHostKeys: expectedHostKeys)
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

private nonisolated final class ForwardingWireConnectionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func set(_ value: Int) { lock.withLock { count = value } }
}

private nonisolated final class ForwardingWireConnections: @unchecked Sendable {
    struct Entry: Sendable {
        let id: UUID
        let connection: SSHForwardingConnection
        let failureHandler: SSHForwardingConnection.FailureHandler
    }

    private let lock = NSLock()
    private var stored: [Entry] = []
    var entries: [Entry] { lock.withLock { stored } }

    func make(
        id: UUID, connectionHandler: @escaping SSHForwardingConnection.ConnectionHandler,
        failureHandler: @escaping SSHForwardingConnection.FailureHandler
    ) -> SSHForwardingConnection {
        let connection = SSHForwardingConnection(
            connectionHandler: connectionHandler, failureHandler: failureHandler)
        lock.withLock { stored.append(Entry(id: id, connection: connection, failureHandler: failureHandler)) }
        return connection
    }
}

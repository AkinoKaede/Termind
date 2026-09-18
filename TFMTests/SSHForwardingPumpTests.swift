import CSSH2
import Darwin
import Foundation
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHForwardingPumpTests {
    @Test func blockedWriteKeepsItsPointerLengthAndBytesWhileMoreDataArrives() {
        let queue = SSHByteQueue()
        queue.append(Data(repeating: 0x31, count: 100))
        let original = queue.withFirstBytes { (UInt(bitPattern: $0.baseAddress!), $0.count, Data($0)) }
        for _ in 0..<100 { queue.append(Data(repeating: 0x72, count: 32768)) }
        for _ in 0..<5 {
            queue.withFirstBytes {
                #expect(UInt(bitPattern: $0.baseAddress!) == original.0)
                #expect($0.count == original.1)
                #expect(Data($0) == original.2)
            }
        }
        queue.consume(37)
        queue.withFirstBytes {
            #expect(UInt(bitPattern: $0.baseAddress!) == original.0 + 37)
            #expect(Data($0) == Data(repeating: 0x31, count: 63))
        }
        queue.consume(63)
        #expect(queue.withFirstBytes { Data($0) } == Data(repeating: 0x72, count: 32768))
    }

    @Test func chunkCompactionPreservesOrderAndReleasesConsumedBytes() {
        let queue = SSHByteQueue()
        for value in UInt8(0)..<200 { queue.append(contentsOf: [value]) }
        for value in UInt8(0)..<200 {
            #expect(queue.withFirstBytes { Array($0) } == [value])
            queue.consume(1)
            #expect(queue.count == 199 - Int(value))
        }
        #expect(queue.isEmpty)
        queue.append(contentsOf: [255])
        #expect(queue.withFirstBytes { Array($0) } == [255])
    }

    @Test func readyQueueDeduplicatesAndPutsHotStreamsBehindPeers() {
        var ready = SSHReadyQueue<Int>()
        for value in 0..<100 {
            ready.insert(value)
            ready.insert(value)
        }
        for value in 0..<100 {
            #expect(ready.pop() == value)
            ready.insert(value)
        }
        for value in 0..<100 { #expect(ready.pop() == value) }
        #expect(ready.pop() == nil)
    }

    @Test func cancellingSuspendedSourcesClosesOnlyAfterBothHandlersRetire() async throws {
        let descriptors = try pair()
        defer { Darwin.close(descriptors[1]) }
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "forwarding-source-test")
            queue.async {
                let events = SSHSocketEvents(socket: descriptors[0], queue: queue) {
                    Issue.record("A cancelled source delivered readiness")
                }
                events.cancel {
                    #expect(fcntl(descriptors[0], F_GETFD) >= 0)
                    Darwin.close(descriptors[0])
                    continuation.resume()
                }
            }
        }
    }

    @Test func targetConnectionCanBeCancelledDuringDNSWithoutLateDelivery() async {
        let queue = DispatchQueue(label: "forwarding-connect-test")
        await withCheckedContinuation { continuation in
            queue.async {
                let connector = SSHForwardingConnector(queue: queue) { result in
                    if case .success(let socket) = result { Darwin.close(socket) }
                    Issue.record("Cancelled target delivered a result")
                }
                connector.start(host: "localhost", port: 1)
                connector.cancel()
                queue.asyncAfter(deadline: .now() + 0.1) {
                    _ = connector
                    continuation.resume()
                }
            }
        }
    }

    @Test func repeatedEAGAINRetainsTheOriginalWriteAndPreservesLaterData() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        var attempts: [(UInt, Data)] = []
        var delivered = Data()
        var io = idleIO()
        io.write = { _, bytes in
            attempts.append((UInt(bitPattern: bytes.baseAddress!), Data(bytes)))
            if attempts.count <= 2 { return Int(LIBSSH2_ERROR_EAGAIN) }
            let count = min(7, bytes.count)
            delivered.append(contentsOf: bytes.prefix(count))
            return count
        }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        var scratch = [UInt8](repeating: 0, count: 32768)
        let first = Data(repeating: 31, count: 20)
        let second = Data(repeating: 72, count: 13)
        first.withUnsafeBytes { _ = Darwin.send(sockets[1], $0.baseAddress!, $0.count, 0) }
        _ = try stream.pump(session: handle, scratch: &scratch)
        second.withUnsafeBytes { _ = Darwin.send(sockets[1], $0.baseAddress!, $0.count, 0) }
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(attempts.count == 2)
        #expect(attempts[0].0 == attempts[1].0)
        #expect(attempts[0].1 == first && attempts[1].1 == first)
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(delivered == first + second)
        #expect(stream.toChannel.isEmpty)
    }

    @Test func backpressureParksSocketReadsAndResumesAfterDraining() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        for socket in sockets { _ = fcntl(socket, F_SETFL, O_NONBLOCK) }
        var blocked = true
        var io = idleIO()
        io.write = { _, bytes in blocked ? Int(LIBSSH2_ERROR_EAGAIN) : bytes.count }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        var scratch = [UInt8](repeating: 0, count: 32768)
        stream.toChannel.append(Data(repeating: 42, count: SSHStreamPump.highWater))
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(stream.toChannel.count == SSHStreamPump.highWater)
        #expect(!stream.wantsSocketRead)
        blocked = false
        for _ in 0..<10 { _ = try stream.pump(session: handle, scratch: &scratch) }
        #expect(stream.toChannel.isEmpty)
        #expect(stream.wantsSocketRead)
    }

    @Test func halfCloseWaitsForPendingWritesAndStillDeliversTheResponse() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        var blocked = true
        var sentEOF = 0
        var sentResponse = false
        var io = idleIO()
        io.write = { _, bytes in blocked ? Int(LIBSSH2_ERROR_EAGAIN) : bytes.count }
        io.sendEOF = { _ in
            sentEOF += 1
            return 0
        }
        io.read = { _, bytes in
            guard !blocked, !sentResponse else { return Int(LIBSSH2_ERROR_EAGAIN) }
            bytes[0] = 99
            sentResponse = true
            return 1
        }
        io.eof = { _ in sentResponse ? 1 : 0 }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        stream.toChannel.append(contentsOf: [42])
        _ = Darwin.shutdown(sockets[1], SHUT_WR)
        var scratch = [UInt8](repeating: 0, count: 32768)
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(sentEOF == 0)
        blocked = false
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(sentEOF == 1)
        #expect(stream.finished)
        var byte: UInt8 = 0
        #expect(Darwin.recv(sockets[1], &byte, 1, 0) == 1)
        #expect(byte == 99)
        #expect(Darwin.recv(sockets[1], &byte, 1, 0) == 0)
    }

    @Test func aWindowUpdateWithoutPayloadSchedulesTheBlockedWriterAgain() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        var window: UInt = 0
        var io = idleIO()
        io.write = { _, bytes in window == 0 ? Int(LIBSSH2_ERROR_EAGAIN) : bytes.count }
        io.writeWindow = { _ in window }
        io.read = { _, _ in
            window = 32768
            return Int(LIBSSH2_ERROR_EAGAIN)
        }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        stream.toChannel.append(contentsOf: [42])
        var scratch = [UInt8](repeating: 0, count: 32768)
        #expect(try stream.pump(session: handle, scratch: &scratch))
        #expect(stream.toChannel.count == 1)
        #expect(try stream.pump(session: handle, scratch: &scratch))
        #expect(stream.toChannel.isEmpty)
    }

    @Test func encryptedPacketsSurviveSocketBackpressureWithoutLibrarySendRetries() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        for socket in sockets { _ = fcntl(socket, F_SETFL, O_NONBLOCK) }
        var capacity: Int32 = 4096
        setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size))
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        let transport = SSHBufferedTransport(session: session)
        defer { transport.dispose(session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, callback)
        typealias Send =
            @convention(c) (
                Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let send = unsafeBitCast(callback, to: Send.self)
        var expected = Data()
        for index in 0..<100 where !transport.isBackpressured {
            let packet = Data(repeating: UInt8(index), count: 32768)
            expected.append(packet)
            let result = packet.withUnsafeBytes {
                send(sockets[0], $0.baseAddress!, $0.count, 0, libssh2_session_abstract(session))
            }
            #expect(result == packet.count)
        }
        #expect(transport.isBackpressured)
        #expect(expected.count <= SSHStreamPump.highWater + 65536)
        var actual = Data()
        var scratch = [UInt8](repeating: 0, count: 32768)
        for _ in 0..<1000 {
            let count = Darwin.recv(sockets[1], &scratch, scratch.count, 0)
            if count > 0 { actual.append(contentsOf: scratch.prefix(count)) }
            try transport.flush(socket: sockets[0])
            if actual.count == expected.count { break }
        }
        #expect(actual == expected)
        #expect(!transport.wantsWrite)
    }

    @Test func cancellingAZeroWindowWriteDoesNotWaitForThePeerToRead() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        var io = idleIO()
        var writes = 0
        io.write = { _, _ in
            writes += 1
            return Int(LIBSSH2_ERROR_EAGAIN)
        }
        io.writeWindow = { _ in 0 }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        stream.toChannel.append(Data(repeating: 42, count: 32768))
        var scratch = [UInt8](repeating: 0, count: 32768)
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(stream.writePending)
        #expect(stream.finishPendingWrite(session: handle))
        #expect(!stream.writePending)
        #expect(writes == 1)
    }

    @Test func continuousEncryptedInputYieldsAtTheSessionReadBudget() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        for socket in sockets { _ = fcntl(socket, F_SETFL, O_NONBLOCK) }
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        let transport = SSHBufferedTransport(session: session)
        defer { transport.dispose(session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, callback)
        typealias Receive =
            @convention(c) (
                Int32, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let receive = unsafeBitCast(callback, to: Receive.self)
        var packet = [UInt8](repeating: 42, count: 4096)
        for _ in 0..<(SSHStreamPump.quantum / packet.count) {
            try #require(Darwin.send(sockets[1], &packet, packet.count, 0) == packet.count)
            try #require(
                receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == packet.count)
        }
        #expect(transport.exhaustedReadBudget)
        try #require(Darwin.send(sockets[1], &packet, packet.count, 0) == packet.count)
        #expect(receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == -Int(EAGAIN))
        transport.beginPass()
        #expect(receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == packet.count)
    }

    private func idleIO() -> SSHChannelIO {
        SSHChannelIO(
            read: { _, _ in Int(LIBSSH2_ERROR_EAGAIN) }, write: { _, bytes in bytes.count },
            writeWindow: { _ in 32768 }, eof: { _ in 0 }, sendEOF: { _ in 0 },
            directions: { _ in LIBSSH2_SESSION_BLOCK_INBOUND })
    }

    private func pair() throws -> [Int32] {
        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw POSIXError(.EIO) }
        return sockets
    }
}

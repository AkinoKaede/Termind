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

    @Test func bridgeBufferGrowthPreservesNonblockingIOAndLargerExistingBuffers() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        let tuning = SSHForwardingTuning.current
        tuning.configureBridgeSocket(sockets[0])
        #expect(fcntl(sockets[0], F_GETFL) & O_NONBLOCK != 0)
        var size = socklen_t(MemoryLayout<Int32>.size)
        var previous: Int32 = 0
        try #require(getsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &previous, &size) == 0)
        var smaller = tuning
        smaller.bridgeSocketBuffer = 4096
        smaller.configureBridgeSocket(sockets[0])
        var current: Int32 = 0
        try #require(getsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &current, &size) == 0)
        #expect(current == previous)
        var byte: UInt8 = 42
        try #require(Darwin.send(sockets[0], &byte, 1, 0) == 1)
        byte = 0
        try #require(Darwin.recv(sockets[1], &byte, 1, 0) == 1)
        #expect(byte == 42)
        // A failed option query is best-effort and must not become a connection error.
        tuning.configureBridgeSocket(-1)
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
        stream.toChannel.append(Data(repeating: 42, count: SSHForwardingTuning.current.highWater))
        _ = try stream.pump(session: handle, scratch: &scratch)
        #expect(stream.toChannel.count == SSHForwardingTuning.current.highWater)
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
        let buffer = SSHConnectionBuffer(libssh2Session: session)
        defer { buffer.dispose(libssh2Session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, callback)
        typealias Send =
            @convention(c) (
                Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let send = unsafeBitCast(callback, to: Send.self)
        var expected = Data()
        for index in 0..<100 where !buffer.isBackpressured {
            let packet = Data(repeating: UInt8(index), count: 32768)
            expected.append(packet)
            let result = packet.withUnsafeBytes {
                send(sockets[0], $0.baseAddress!, $0.count, 0, libssh2_session_abstract(session))
            }
            #expect(result == packet.count)
        }
        #expect(buffer.isBackpressured)
        #expect(expected.count <= SSHForwardingTuning.current.highWater + 65536)
        var actual = Data()
        var scratch = [UInt8](repeating: 0, count: 32768)
        for _ in 0..<1000 {
            let count = Darwin.recv(sockets[1], &scratch, scratch.count, 0)
            if count > 0 { actual.append(contentsOf: scratch.prefix(count)) }
            buffer.beginPass()
            try buffer.flush(socket: sockets[0])
            if actual.count == expected.count { break }
        }
        #expect(actual == expected)
        #expect(!buffer.wantsWrite)
    }

    @Test func encryptedFlushesShareOneAllowanceUntilTheNextPass() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        for socket in sockets { _ = fcntl(socket, F_SETFL, O_NONBLOCK) }
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        let buffer = SSHConnectionBuffer(libssh2Session: session, tuning: SSHForwardingTuning(quantum: 100))
        defer { buffer.dispose(libssh2Session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_SEND, callback)
        typealias Send =
            @convention(c) (
                Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let send = unsafeBitCast(callback, to: Send.self)
        var bytes = [UInt8](repeating: 42, count: 4096)
        // Fill the kernel socket first, so the complete encrypted packet is queued.
        while Darwin.send(sockets[0], &bytes, bytes.count, MSG_DONTWAIT) > 0 {}
        try #require(errno == EAGAIN || errno == EWOULDBLOCK)
        try #require(send(sockets[0], &bytes, bytes.count, 0, libssh2_session_abstract(session)) == bytes.count)
        while Darwin.recv(sockets[1], &bytes, bytes.count, MSG_DONTWAIT) > 0 {}
        buffer.beginPass()
        try buffer.flush(socket: sockets[0])
        try buffer.flush(socket: sockets[0])
        #expect(Darwin.recv(sockets[1], &bytes, bytes.count, MSG_DONTWAIT) == 100)
        #expect(buffer.wantsWrite)
        buffer.beginPass()
        try buffer.flush(socket: sockets[0])
        #expect(Darwin.recv(sockets[1], &bytes, bytes.count, MSG_DONTWAIT) == 100)
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

    @Test(arguments: [256 * 1024, 1024 * 1024, 4 * 1024 * 1024])
    func continuousEncryptedInputYieldsAtTheSessionReadBudget(_ budget: Int) throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        for socket in sockets { _ = fcntl(socket, F_SETFL, O_NONBLOCK) }
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        let buffer = SSHConnectionBuffer(libssh2Session: session, tuning: SSHForwardingTuning(readBudget: budget))
        defer { buffer.dispose(libssh2Session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, callback)
        typealias Receive =
            @convention(c) (
                Int32, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let receive = unsafeBitCast(callback, to: Receive.self)
        var packet = [UInt8](repeating: 42, count: 4096)
        for _ in 0..<(budget / packet.count) {
            try #require(Darwin.send(sockets[1], &packet, packet.count, 0) == packet.count)
            try #require(
                receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == packet.count)
        }
        #expect(buffer.exhaustedReadBudget)
        try #require(Darwin.send(sockets[1], &packet, packet.count, 0) == packet.count)
        #expect(receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == -Int(EAGAIN))
        buffer.beginPass()
        #expect(receive(sockets[0], &packet, packet.count, 0, libssh2_session_abstract(session)) == packet.count)
    }

    @Test func vectoredWritesRespectByteAndChunkLimitsAfterACrossChunkShortWrite() {
        let bytes = SSHByteQueue()
        for value in UInt8(0)..<20 { bytes.append(Data(repeating: value, count: 100)) }
        bytes.withVectors(limit: 10000) { vectors in
            #expect(vectors.count == 16)
            #expect(vectors.reduce(0) { $0 + $1.iov_len } == 1600)
        }
        // A short send accepted two whole chunks and part of the third.
        bytes.consume(237)
        bytes.withVectors(limit: 120) { vectors in
            #expect(vectors.map(\.iov_len) == [63, 57])
            let actual = vectors.reduce(into: Data()) {
                $0.append($1.iov_base!.assumingMemoryBound(to: UInt8.self), count: $1.iov_len)
            }
            #expect(actual == Data(repeating: 2, count: 63) + Data(repeating: 3, count: 57))
        }
        bytes.consume(1763)
        #expect(bytes.isEmpty)
        bytes.withVectors(limit: 1) { #expect($0.isEmpty) }
    }

    @Test func channelInputDoesNotCreateATinyTailForEveryLibssh2Write() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        var capacity: Int32 = 128 * 1024
        for socket in sockets {
            try #require(setsockopt(socket, SOL_SOCKET, SO_SNDBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)) == 0)
            try #require(setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &capacity, socklen_t(MemoryLayout<Int32>.size)) == 0)
        }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        var sizes: [Int] = []
        var io = idleIO()
        io.write = { _, bytes in
            sizes.append(bytes.count)
            return min(bytes.count, 32_700)
        }
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: io)
        let payload = [UInt8](repeating: 42, count: 2 * 32_700)
        try #require(payload.withUnsafeBytes { Darwin.send(sockets[1], $0.baseAddress!, $0.count, 0) } == payload.count)
        var scratch = [UInt8](repeating: 0, count: 32 * 1024)
        #expect(try stream.pump(session: handle, scratch: &scratch))
        #expect(sizes == [32_700, 32_700])
        #expect(stream.toChannel.isEmpty)
        // SOCKS payload already read alongside the handshake uses the same split.
        stream.toChannel.append(Data(payload))
        sizes.removeAll()
        #expect(try stream.pump(session: handle, scratch: &scratch))
        #expect(sizes == [32_700, 32_700])
    }

    @Test func socketOutputBatchesChunksAndResumesAfterItsQuantum() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        let stream = SSHStreamPump(socket: sockets[0], tuning: SSHForwardingTuning(quantum: 100))
        for value in UInt8(0)..<10 { stream.toSocket.append(Data(repeating: value, count: 20)) }
        #expect(try stream.flushSocket())
        #expect(stream.socketWriteCalls == 1)
        #expect(stream.toSocket.count == 100)
        #expect(try stream.flushSocket())
        #expect(stream.socketWriteCalls == 2)
        var received = [UInt8](repeating: 0, count: 200)
        #expect(Darwin.recv(sockets[1], &received, received.count, MSG_WAITALL) == 200)
        #expect(received == (UInt8(0)..<10).flatMap { Array(repeating: $0, count: 20) })
    }

    @Test func anExpiredSlicePreservesQueuedDataAndResumesWithoutASocketEdge() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        _ = fcntl(sockets[0], F_SETFL, O_NONBLOCK)
        let handle = OpaquePointer(bitPattern: 1)!
        let stream = SSHStreamPump(socket: sockets[0], channel: handle, io: idleIO())
        stream.toChannel.append(contentsOf: [42])
        var scratch = [UInt8](repeating: 0, count: 32)
        #expect(try !stream.pump(session: handle, scratch: &scratch, deadline: 0))
        #expect(stream.yielded)
        #expect(stream.toChannel.count == 1)
        #expect(try stream.pump(session: handle, scratch: &scratch))
        #expect(!stream.yielded)
        #expect(stream.toChannel.isEmpty)
    }

    @Test func aDeferredControlReplyDoesNotKeepReschedulingAfterItDrains() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        let stream = SSHStreamPump(socket: sockets[0])
        stream.toSocket.append(contentsOf: [5, 0])
        stream.beginTurn()
        #expect(try !stream.flushSocket(deadline: 0))
        #expect(stream.yielded)
        stream.beginTurn()
        #expect(try stream.flushSocket())
        #expect(!stream.yielded)
        #expect(stream.toSocket.isEmpty)
        stream.beginTurn()
        #expect(try !stream.flushSocket())
        #expect(!stream.yielded)
    }

    @Test func encryptedReceiveYieldsAtTheDeadlineBeforeSpendingItsByteBudget() throws {
        let sockets = try pair()
        defer { for socket in sockets { Darwin.close(socket) } }
        let session = try #require(libssh2_session_init_ex(nil, nil, nil, nil))
        let buffer = SSHConnectionBuffer(libssh2Session: session)
        defer { buffer.dispose(libssh2Session: session) }
        let callback = try #require(libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, nil))
        libssh2_session_callback_set2(session, LIBSSH2_CALLBACK_RECV, callback)
        typealias Receive =
            @convention(c) (
                Int32, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
            ) -> Int
        let receive = unsafeBitCast(callback, to: Receive.self)
        var byte: UInt8 = 42
        try #require(Darwin.send(sockets[1], &byte, 1, 0) == 1)
        buffer.beginPass(deadline: 0)
        #expect(receive(sockets[0], &byte, 1, 0, libssh2_session_abstract(session)) == -Int(EAGAIN))
        #expect(buffer.exhaustedReadBudget)
        buffer.beginPass()
        #expect(receive(sockets[0], &byte, 1, 0, libssh2_session_abstract(session)) == 1)
        #expect(!buffer.exhaustedReadBudget)
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

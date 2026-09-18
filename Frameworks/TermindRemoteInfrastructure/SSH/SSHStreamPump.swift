import CSSH2
import Darwin
import Foundation

/// Queue-confined chunks keep libssh2's retry pointer and length stable even when
/// new socket data arrives while an earlier write is blocked.
nonisolated final class SSHByteQueue {
    private final class Chunk {
        let bytes: UnsafeMutableRawPointer
        let size: Int
        var offset = 0

        init(_ source: UnsafeRawBufferPointer) {
            size = source.count
            bytes = .allocate(byteCount: size, alignment: 1)
            bytes.copyMemory(from: source.baseAddress!, byteCount: size)
        }

        deinit { bytes.deallocate() }
    }

    private var chunks: [Chunk?] = []
    private var head = 0
    private(set) var count = 0
    var isEmpty: Bool { count == 0 }

    func append(_ data: Data) { data.withUnsafeBytes { append($0) } }
    func append(contentsOf bytes: [UInt8]) { bytes.withUnsafeBytes { append($0) } }

    func append(_ bytes: UnsafeRawBufferPointer) {
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + 32 * 1024, bytes.count)
            chunks.append(Chunk(UnsafeRawBufferPointer(rebasing: bytes[offset..<end])))
            offset = end
        }
        count += bytes.count
    }

    func withFirstBytes<T>(_ body: (UnsafeRawBufferPointer) -> T) -> T {
        guard head < chunks.count, let chunk = chunks[head] else {
            return body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        return body(UnsafeRawBufferPointer(start: chunk.bytes + chunk.offset, count: chunk.size - chunk.offset))
    }

    func removeAll() {
        chunks.removeAll()
        head = 0
        count = 0
    }

    func consume(_ size: Int) {
        precondition(size > 0 && size <= count)
        let chunk = chunks[head]!
        precondition(size <= chunk.size - chunk.offset)
        chunk.offset += size
        count -= size
        if chunk.offset == chunk.size {
            chunks[head] = nil
            head += 1
            if head == chunks.count {
                chunks.removeAll(keepingCapacity: true)
                head = 0
            } else if head >= 64 && head * 2 >= chunks.count {
                chunks.removeFirst(head)
                head = 0
            }
        }
    }
}

/// Sources, interest changes and their handlers all belong to the supplied queue.
/// Closing the descriptor must wait for both cancellation handlers, including
/// when a source was suspended for backpressure.
nonisolated final class SSHSocketEvents {
    private let read: any DispatchSourceRead
    private let write: any DispatchSourceWrite
    private let queue: DispatchQueue
    private let cancelled = DispatchGroup()
    private var reading = false
    private var writing = false
    private var stopped = false

    init(socket: Int32, queue: DispatchQueue, ready: @escaping @Sendable () -> Void) {
        self.queue = queue
        read = DispatchSource.makeReadSource(fileDescriptor: socket, queue: queue)
        write = DispatchSource.makeWriteSource(fileDescriptor: socket, queue: queue)
        for source in [read as any DispatchSourceProtocol, write as any DispatchSourceProtocol] {
            cancelled.enter()
            source.setCancelHandler { [cancelled] in cancelled.leave() }
            source.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                ready()
            }
        }
    }

    func update(read wantsRead: Bool, write wantsWrite: Bool) {
        guard !stopped else { return }
        if wantsRead != reading {
            reading = wantsRead
            if reading { read.resume() } else { read.suspend() }
        }
        if wantsWrite != writing {
            writing = wantsWrite
            if writing { write.resume() } else { write.suspend() }
        }
    }

    func cancel(then completion: @escaping @Sendable () -> Void = {}) {
        guard !stopped else { return }
        stopped = true
        read.cancel()
        write.cancel()
        if !reading { read.resume() }
        if !writing { write.resume() }
        cancelled.notify(queue: queue, execute: completion)
    }
}

/// Deduplicated FIFO; a hot stream goes behind its peers rather than monopolizing
/// the session queue. Also used for listener/channel work that must retain order.
nonisolated struct SSHReadyQueue<Element: Hashable> {
    private var items: [Element] = []
    private var members: Set<Element> = []
    private var head = 0
    var isEmpty: Bool { members.isEmpty }

    mutating func insert(_ item: Element) {
        if members.insert(item).inserted { items.append(item) }
    }

    mutating func pop() -> Element? {
        guard head < items.count else { return nil }
        let item = items[head]
        members.remove(item)
        head += 1
        if head == items.count {
            items.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64 && head * 2 >= items.count {
            items.removeFirst(head)
            head = 0
        }
        return item
    }
}

/// Internal I/O seam: production uses libssh2; tests can force short writes,
/// blocked windows and EOF independently of operating-system timing.
nonisolated struct SSHChannelIO {
    var read: (OpaquePointer, UnsafeMutableRawBufferPointer) -> Int = {
        libssh2_channel_read_ex($0, 0, $1.baseAddress!.assumingMemoryBound(to: CChar.self), $1.count)
    }
    var write: (OpaquePointer, UnsafeRawBufferPointer) -> Int = {
        libssh2_channel_write_ex($0, 0, $1.baseAddress!.assumingMemoryBound(to: CChar.self), $1.count)
    }
    var writeWindow: (OpaquePointer) -> UInt = { libssh2_channel_window_write_ex($0, nil) }
    var eof: (OpaquePointer) -> Int32 = { libssh2_channel_eof($0) }
    var sendEOF: (OpaquePointer) -> Int32 = { libssh2_channel_send_eof($0) }
    var directions: (OpaquePointer) -> Int32 = { libssh2_session_block_directions($0) }
}

/// A socket/channel pair. Its owner serializes every call with all other calls
/// on the same SSH session, and provides a reusable scratch buffer.
nonisolated final class SSHStreamPump {
    static let highWater = 2 * 1024 * 1024
    static let lowWater = 1024 * 1024
    static let quantum = 256 * 1024

    private let io: SSHChannelIO
    var socket: Int32
    var channel: OpaquePointer?
    let toChannel = SSHByteQueue()
    let toSocket = SSHByteQueue()
    var socketEOF = false
    var channelEOF = false
    var socketWriteClosed = false
    var channelWriteClosed = false
    private(set) var writePending = false
    private(set) var blockDirections: Int32 = 0
    private var socketReadPaused = false
    private var channelReadPaused = false
    private(set) var socketWriteBlocked = false

    init(socket: Int32, channel: OpaquePointer? = nil, io: SSHChannelIO = SSHChannelIO()) {
        self.io = io
        self.socket = socket
        self.channel = channel
    }

    var wantsSocketRead: Bool { !socketEOF && !socketReadPaused }
    var wantsChannelRead: Bool { !channelEOF && !channelReadPaused }
    var finished: Bool { socketEOF && channelEOF && toChannel.isEmpty && toSocket.isEmpty }

    func blocked(_ session: OpaquePointer) {
        blockDirections |= io.directions(session)
    }

    /// Returns whether bytes/EOF moved. Even a final successful read can have
    /// buffered packets for another channel: the owner schedules another sweep.
    func pump(session: OpaquePointer, scratch: inout [UInt8]) throws -> Bool {
        blockDirections = 0
        socketWriteBlocked = false
        var progressed = false
        var waitingForWindow = false
        if socketReadPaused && toChannel.count <= Self.lowWater { socketReadPaused = false }
        if channelReadPaused && toSocket.count <= Self.lowWater { channelReadPaused = false }
        var remaining = Self.quantum
        while wantsSocketRead && remaining > 0 {
            let capacity = min(scratch.count, remaining, Self.highWater - toChannel.count)
            if capacity == 0 {
                socketReadPaused = true
                break
            }
            let count = Darwin.recv(socket, &scratch, capacity, 0)
            if count > 0 {
                scratch.withUnsafeBytes { toChannel.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                remaining -= count
                progressed = true
            } else if count == 0 {
                socketEOF = true
                progressed = true
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        if toChannel.count >= Self.highWater { socketReadPaused = true }
        if let channel {
            remaining = Self.quantum
            while !toChannel.isEmpty && remaining > 0 {
                let written = try write(session: session, channel: channel)
                if written == 0 {
                    waitingForWindow = io.writeWindow(channel) == 0
                    break
                }
                remaining -= written
                progressed = true
            }
            if socketEOF && toChannel.isEmpty && !channelWriteClosed {
                let result = io.sendEOF(channel)
                if result == 0 {
                    channelWriteClosed = true
                    progressed = true
                } else if result == LIBSSH2_ERROR_EAGAIN {
                    blocked(session)
                } else {
                    throw StreamError.closed
                }
            }
            remaining = Self.quantum
            while wantsChannelRead && remaining > 0 {
                let capacity = min(scratch.count, remaining, Self.highWater - toSocket.count)
                if capacity == 0 {
                    channelReadPaused = true
                    break
                }
                let count = scratch.withUnsafeMutableBytes {
                    io.read(channel, UnsafeMutableRawBufferPointer(rebasing: $0[..<capacity]))
                }
                if count > 0 {
                    scratch.withUnsafeBytes { toSocket.append(UnsafeRawBufferPointer(rebasing: $0[..<count])) }
                    remaining -= count
                    progressed = true
                } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                    blocked(session)
                    break
                } else {
                    throw StreamError.closed
                }
            }
            if !channelEOF && io.eof(channel) == 1 {
                channelEOF = true
                progressed = true
            }
        }
        if toSocket.count >= Self.highWater { channelReadPaused = true }
        if try flushSocket() { progressed = true }
        if channelEOF && toSocket.isEmpty && !socketWriteClosed {
            _ = Darwin.shutdown(socket, SHUT_WR)
            socketWriteClosed = true
            progressed = true
        }
        if waitingForWindow, let channel, io.writeWindow(channel) > 0 { progressed = true }
        return progressed
    }

    func flushSocket() throws -> Bool {
        var remaining = Self.quantum
        var progressed = false
        socketWriteBlocked = false
        while !toSocket.isEmpty && remaining > 0 {
            let sent = toSocket.withFirstBytes { Darwin.send(socket, $0.baseAddress!, $0.count, 0) }
            if sent > 0 {
                toSocket.consume(sent)
                remaining -= sent
                progressed = true
            } else if sent < 0 && errno == EINTR {
                continue
            } else if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                socketWriteBlocked = true
                break
            } else {
                throw StreamError.closed
            }
        }
        return progressed
    }

    /// Finish an already-started write before freeing a retired channel. The SSH
    /// transport may still own this channel's packet, so simply dropping it can
    /// prevent every peer from writing.
    func finishPendingWrite(session: OpaquePointer) -> Bool {
        guard writePending, let channel else { return true }
        // A zero-window write has not entered libssh2's packet-send state.
        // Cancellation must not wait for a peer that will never read again.
        if io.writeWindow(channel) == 0 {
            writePending = false
            return true
        }
        do { _ = try write(session: session, channel: channel) } catch { writePending = false }
        return !writePending
    }

    private func write(session: OpaquePointer, channel: OpaquePointer) throws -> Int {
        let written = toChannel.withFirstBytes {
            io.write(channel, $0)
        }
        if written > 0 {
            writePending = false
            toChannel.consume(written)
            return written
        }
        if written == LIBSSH2_ERROR_EAGAIN || written == 0 {
            writePending = true
            blocked(session)
            return 0
        }
        writePending = false
        throw StreamError.closed
    }

    enum StreamError: Error { case closed }
}

import CSSH2
import Darwin
import Foundation

/// Queue-confined encrypted output. libssh2's forwarded-tcpip confirmation
/// retry loses its pending channel in the pinned library when send returns
/// EAGAIN. Accept complete packets here and apply backpressure between library
/// calls instead. The receive callback also stops packet processing at the
/// watermark, bounding replies generated while libssh2 drains input.
nonisolated final class SSHBufferedTransport {
    private let output = SSHByteQueue()
    private var disposed = false
    private var readAllowance = SSHStreamPump.quantum
    var exhaustedReadBudget: Bool { readAllowance == 0 }

    func beginPass() { readAllowance = SSHStreamPump.quantum }
    var isBackpressured: Bool { output.count >= SSHStreamPump.highWater }
    var wantsWrite: Bool { !output.isEmpty }

    init(session: OpaquePointer) {
        libssh2_session_abstract(session)?.pointee = Unmanaged.passUnretained(self).toOpaque()
        libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_SEND, unsafeBitCast(Self.send, to: (@convention(c) () -> Void).self))
        libssh2_session_callback_set2(
            session, LIBSSH2_CALLBACK_RECV, unsafeBitCast(Self.receive, to: (@convention(c) () -> Void).self))
    }

    func flush(socket: Int32) throws {
        while !output.isEmpty {
            let count = output.withFirstBytes { Darwin.send(socket, $0.baseAddress!, $0.count, MSG_DONTWAIT) }
            if count > 0 {
                output.consume(count)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return
            } else {
                throw SSHStreamPump.StreamError.closed
            }
        }
    }

    /// Teardown cannot wait on a peer. Discard final protocol writes and return
    /// EOF to reads, so libssh2 can release channels/listeners without EAGAIN.
    func dispose(session: OpaquePointer) {
        disposed = true
        let result = libssh2_session_free(session)
        assert(result == 0, "SSH session disposal must finish without socket I/O")
    }

    private static let send:
        @convention(c) (
            Int32, UnsafeRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        ) -> Int = { socket, bytes, count, flags, abstract in
            guard let opaque = abstract?.pointee, let bytes else { return -Int(EINVAL) }
            let transport = Unmanaged<SSHBufferedTransport>.fromOpaque(opaque).takeUnretainedValue()
            if transport.disposed { return count }
            var sent = 0
            if transport.output.isEmpty {
                repeat {
                    sent = Darwin.send(socket, bytes, count, flags | MSG_DONTWAIT)
                } while sent < 0 && errno == EINTR
                if sent < 0 {
                    guard errno == EAGAIN || errno == EWOULDBLOCK else { return -Int(errno) }
                    sent = 0
                }
            }
            if sent < count {
                transport.output.append(UnsafeRawBufferPointer(start: bytes + sent, count: count - sent))
            }
            return count
        }

    private static let receive:
        @convention(c) (
            Int32, UnsafeMutableRawPointer?, Int, Int32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?
        ) -> Int = { socket, bytes, count, flags, abstract in
            guard let opaque = abstract?.pointee else { return -Int(EINVAL) }
            let transport = Unmanaged<SSHBufferedTransport>.fromOpaque(opaque).takeUnretainedValue()
            if transport.disposed { return 0 }
            if transport.isBackpressured || transport.exhaustedReadBudget { return -Int(EAGAIN) }
            let received = Darwin.recv(socket, bytes, min(count, transport.readAllowance), flags | MSG_DONTWAIT)
            if received > 0 { transport.readAllowance -= received }
            return received < 0 ? -Int(errno) : received
        }
}

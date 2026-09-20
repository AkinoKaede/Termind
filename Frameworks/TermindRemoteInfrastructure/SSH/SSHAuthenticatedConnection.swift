import CSSH2
import Foundation

/// One authenticated SSH connection.
///
/// `SSHRoutedSocket` is only the byte transport. The libssh2 handle carries the
/// SSH transport, user-authentication, and connection-protocol state over that
/// byte stream. PTY, exec, SFTP, and forwarding Channels are opened on
/// this connection; they are not transports themselves.
public nonisolated final class SSHAuthenticatedConnection: @unchecked Sendable {
    public let byteTransport: SSHRoutedSocket
    public let libssh2Session: OpaquePointer

    private let lock = NSLock()
    private var buffer: SSHConnectionBuffer?
    private var isClosed = false

    public init(byteTransport: SSHRoutedSocket, libssh2Session: OpaquePointer) {
        self.byteTransport = byteTransport
        self.libssh2Session = libssh2Session
    }

    func installBuffer(tuning: SSHForwardingTuning = .current) -> SSHConnectionBuffer {
        lock.withLock {
            precondition(!isClosed, "Cannot configure I/O for a closed SSH connection")
            if let buffer { return buffer }
            let installed = SSHConnectionBuffer(libssh2Session: libssh2Session, tuning: tuning)
            buffer = installed
            return installed
        }
    }

    func close() {
        let disposition = lock.withLock { () -> (Bool, SSHConnectionBuffer?) in
            guard !isClosed else { return (false, nil) }
            isClosed = true
            defer { buffer = nil }
            return (true, buffer)
        }
        guard disposition.0 else { return }
        if let buffer = disposition.1 {
            buffer.dispose(libssh2Session: libssh2Session)
        } else {
            _ = libssh2_session_free(libssh2Session)
        }
        byteTransport.close()
    }

    deinit { close() }
}

import CSSH2
import Darwin
import Foundation

nonisolated struct SSHExecResult: Hashable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var signal: String?
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
}

/// The one failure that is safe to retry on a fresh connection.
///
/// It is thrown only while the remote command is provably *not running*: the
/// session was already gone, or the channel could not be opened or started.
/// Every failure after `process_startup` succeeds is rethrown unchanged, because
/// by then the command may have partially run and a transparent retry could
/// delete something twice.
nonisolated enum SSHExecSessionError: LocalizedError, Sendable {
    case channelUnavailable(any Error)

    var errorDescription: String? {
        switch self {
        case .channelUnavailable(let underlying): underlying.localizedDescription
        }
    }
}

/// A long-lived authenticated SSH session that runs each command on its own
/// non-PTY channel.
///
/// Splitting connect from execute is the whole point: the handshake, host-key
/// check, and signature are paid once per host instead of once per command, and
/// a jump-host route stops rebuilding every hop for every `ls`. Semantics are
/// unchanged — a command still gets a private channel and a private
/// `/bin/sh -lc`, so there is no shared shell state and no cwd carry-over.
nonisolated protocol SSHExecSessionProtocol: AnyObject, Sendable {
    func connect(using configuration: SSHConnectionConfiguration) async throws
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult
    func disconnect() async
}

/// Called with each chunk the command produces, and which stream it came from —
/// `false` for stdout, `true` for stderr.
///
/// It runs on the session's own serial queue, between two `libssh2` reads, so it
/// must return promptly and must never await: anything it blocks on stalls every
/// command on that host. Appending to a lock-guarded buffer is the intended
/// shape.
typealias SSHExecOutputHandler = @Sendable (Data, Bool) -> Void

actor SSHExecSession: SSHExecSessionProtocol {
    private nonisolated let worker = SSHExecWorker()

    func connect(using configuration: SSHConnectionConfiguration) async throws {
        try await worker.connect(using: configuration)
    }

    /// Actor-isolated, so commands on one session queue behind each other. That
    /// is not incidental: a libssh2 session cannot be driven from two places at
    /// once, and the worker's queue would serialize them anyway.
    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        let cancellation = TransferCancellationToken()
        return try await withTaskCancellationHandler {
            try await worker.execute(
                command, workingDirectory: workingDirectory, stdin: stdin,
                timeout: timeout, outputLimit: outputLimit, cancellation: cancellation,
                onOutput: onOutput
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    func disconnect() async { await worker.disconnect() }
}

private nonisolated final class SSHExecWorker: @unchecked Sendable {
    /// Every libssh2 call for this session happens here, the idle keepalive
    /// included. libssh2 sessions are not thread-safe, and serializing on one
    /// queue is what makes reuse across commands safe at all.
    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.exec")
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var keepaliveTimer: (any DispatchSourceTimer)?
    /// Set when the transport is known to be gone. The next `execute` reports
    /// `channelUnavailable` instead of calling into a session that cannot answer.
    private var isDead = false

    deinit { cleanup() }

    func connect(using configuration: SSHConnectionConfiguration) async throws {
        try await queue.perform {
            self.cleanup()
            let (transport, session) = try SSHSessionWorker.openAuthenticatedSession(
                using: configuration, timeout: 20
            )
            self.routeTransport = transport
            self.session = session
            self.isDead = false
            self.startKeepalive(for: session)
        }
    }

    func disconnect() async { await queue.perform { self.cleanup() } }

    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, cancellation: TransferCancellationToken,
        onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        try await queue.perform {
            do {
                return try self.executeOnQueue(
                    command, workingDirectory: workingDirectory, stdin: stdin,
                    timeout: timeout, outputLimit: outputLimit, cancellation: cancellation,
                    onOutput: onOutput
                )
            } catch {
                // Still on the queue, and the channel defer has already run, so
                // this is the right moment to give the socket back rather than
                // leave a corpse in the pool for the idle sweep to find.
                if self.isDead { self.cleanup() }
                throw error
            }
        }
    }

    private func executeOnQueue(
        _ command: String, workingDirectory: String?, stdin: Data?,
        timeout: TimeInterval, outputLimit: Int, cancellation: TransferCancellationToken,
        onOutput: SSHExecOutputHandler?
    ) throws -> SSHExecResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TermindSSHError.library("The command is empty.")
        }
        guard let session, !isDead else {
            throw SSHExecSessionError.channelUnavailable(TermindSSHError.disconnected)
        }
        // Blocking for the two setup calls, non-blocking for the pump below.
        libssh2_session_set_blocking(session, 1)
        guard let channel = libssh2_channel_open_ex(
            session, "session", 7, 2 * 1_024 * 1_024, 32 * 1_024, nil, 0
        ) else {
            throw notStarted(session, prefix: "Unable to open SSH exec channel")
        }
        // Only a command that ran to completion leaves a channel worth closing
        // politely, and a session worth keeping.
        var completed = false
        defer {
            if completed {
                libssh2_session_set_blocking(session, 1)
                _ = libssh2_channel_free(channel)
            } else {
                // Timed out, cancelled, or the transport failed: the command may
                // still be running and the channel is mid-stream. Blocking here
                // to close it courteously would stall every later command on this
                // host, so give the whole session up instead — `cleanup` frees
                // it, and freeing a session reclaims its channels with it.
                isDead = true
            }
        }

        let effective: String
        if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cwd.isEmpty
        {
            effective = "cd -- \(Self.shellQuote(cwd)) && /bin/sh -lc \(Self.shellQuote(command))"
        } else {
            effective = "/bin/sh -lc \(Self.shellQuote(command))"
        }
        let started = effective.withCString {
            libssh2_channel_process_startup(channel, "exec", 4, $0, UInt32(effective.utf8.count))
        }
        guard started == 0 else {
            throw notStarted(session, prefix: "Unable to start remote command")
        }
        // Past this line the command is running. Nothing below may be retried.
        libssh2_session_set_blocking(session, 0)

        var pendingInput = stdin ?? Data()
        if !pendingInput.isEmpty, pendingInput.last != 0x0A { pendingInput.append(0x0A) }
        var inputOffset = 0
        var sentEOF = pendingInput.isEmpty
        if sentEOF { _ = libssh2_channel_send_eof(channel) }
        var standardOut = Data()
        var standardError = Data()
        var outTruncated = false
        var errorTruncated = false
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let deadline = Date().addingTimeInterval(max(1, min(timeout, 15 * 60)))
        var lastKeepalive = Date()

        while libssh2_channel_eof(channel) == 0 {
            if cancellation.isCancelled { throw CancellationError() }
            if Date() >= deadline { throw TermindSSHError.library("The remote command timed out.") }
            var progressed = false
            if inputOffset < pendingInput.count {
                let written = pendingInput.withUnsafeBytes { bytes in
                    libssh2_channel_write_ex(
                        channel, 0,
                        bytes.baseAddress!.advanced(by: inputOffset)
                            .assumingMemoryBound(to: CChar.self),
                        bytes.count - inputOffset
                    )
                }
                if written > 0 { inputOffset += written; progressed = true }
                else if written != LIBSSH2_ERROR_EAGAIN {
                    throw failed(session, prefix: "Unable to write command input")
                }
            } else if !sentEOF {
                let result = libssh2_channel_send_eof(channel)
                if result == 0 { sentEOF = true; progressed = true }
                else if result != LIBSSH2_ERROR_EAGAIN {
                    throw failed(session, prefix: "Unable to finish command input")
                }
            }
            for stream in [Int32(0), Int32(1)] {
                while true {
                    let count = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                    if count > 0 {
                        progressed = true
                        let chunk = Data(bytes: buffer, count: count)
                        onOutput?(chunk, stream != 0)
                        if stream == 0 {
                            Self.appendCapped(
                                chunk, to: &standardOut, limit: outputLimit,
                                truncated: &outTruncated
                            )
                        } else {
                            Self.appendCapped(
                                chunk, to: &standardError, limit: outputLimit,
                                truncated: &errorTruncated
                            )
                        }
                    } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 { break }
                    else { throw failed(session, prefix: "Unable to read command output") }
                }
            }
            if !progressed {
                // The idle timer cannot fire while this queue is busy, so a
                // long-running quiet command has to keep its own session alive.
                if Date().timeIntervalSince(lastKeepalive) >= 30 {
                    lastKeepalive = Date()
                    var next = Int32(0)
                    let sent = libssh2_keepalive_send(session, &next)
                    if sent < 0, sent != LIBSSH2_ERROR_EAGAIN {
                        throw failed(session, prefix: "SSH keepalive failed")
                    }
                }
                usleep(10_000)
            }
        }
        // Drain bytes buffered alongside EOF.
        for stream in [Int32(0), Int32(1)] {
            while true {
                let count = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                guard count > 0 else { break }
                let chunk = Data(bytes: buffer, count: count)
                onOutput?(chunk, stream != 0)
                if stream == 0 {
                    Self.appendCapped(
                        chunk, to: &standardOut, limit: outputLimit, truncated: &outTruncated
                    )
                } else {
                    Self.appendCapped(
                        chunk, to: &standardError, limit: outputLimit, truncated: &errorTruncated
                    )
                }
            }
        }
        while true {
            let closed = libssh2_channel_close(channel)
            if closed == 0 { break }
            if closed != LIBSSH2_ERROR_EAGAIN {
                throw failed(session, prefix: "Unable to close SSH exec channel")
            }
            if cancellation.isCancelled { throw CancellationError() }
            if Date() >= deadline { throw TermindSSHError.library("The remote command timed out.") }
            usleep(10_000)
        }
        // The remote is done and the channel is closed, so the session is clean
        // and can carry the next command.
        completed = true
        var exitSignal: UnsafeMutablePointer<CChar>?
        var exitSignalLength = 0
        let signalResult = libssh2_channel_get_exit_signal(
            channel, &exitSignal, &exitSignalLength, nil, nil, nil, nil
        )
        let signal: String?
        if signalResult == 0, let exitSignal {
            signal = String(decoding: UnsafeBufferPointer(
                start: exitSignal, count: exitSignalLength
            ).map(UInt8.init(bitPattern:)), as: UTF8.self)
            libssh2_free(session, exitSignal)
        } else {
            signal = nil
        }
        return SSHExecResult(
            stdout: String(decoding: standardOut, as: UTF8.self),
            stderr: String(decoding: standardError, as: UTF8.self),
            exitCode: Int32(libssh2_channel_get_exit_status(channel)),
            signal: signal,
            stdoutTruncated: outTruncated, stderrTruncated: errorTruncated
        )
    }

    /// The command never started, so the caller may open a fresh connection and
    /// try again exactly once.
    private func notStarted(_ session: OpaquePointer, prefix: String) -> SSHExecSessionError {
        SSHExecSessionError.channelUnavailable(failed(session, prefix: prefix))
    }

    /// Records whether the session is still usable, then describes the failure.
    private func failed(_ session: OpaquePointer, prefix: String) -> TermindSSHError {
        let transport: [Int32] = [
            LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT,
            LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_CHANNEL_CLOSED,
        ]
        if transport.contains(libssh2_session_last_errno(session)) { isDead = true }
        return SSHSessionWorker.sessionError(session, prefix: prefix)
    }

    private func startKeepalive(for session: OpaquePointer) {
        libssh2_keepalive_config(session, 1, 30)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self, self.session == session else { return }
            var secondsToNext: Int32 = 0
            let result = libssh2_keepalive_send(session, &secondsToNext)
            if result < 0, result != LIBSSH2_ERROR_EAGAIN {
                self.isDead = true
                self.cleanup()
            }
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func cleanup() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        if let session {
            _ = libssh2_session_disconnect_ex(
                session, SSH_DISCONNECT_BY_APPLICATION, "Termind closed the exec session", ""
            )
            _ = libssh2_session_free(session)
            self.session = nil
        }
        routeTransport?.close()
        routeTransport = nil
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appendCapped(
        _ chunk: Data, to destination: inout Data, limit: Int, truncated: inout Bool
    ) {
        let remaining = max(0, limit - destination.count)
        if chunk.count > remaining { truncated = true }
        if remaining > 0 { destination.append(chunk.prefix(remaining)) }
    }
}

import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

/// One authenticated SSH connection with any number of non-PTY exec Channels.
///
/// libssh2 itself is never entered concurrently. Every call is made by `queue`,
/// while command state machines take bounded turns from `ready`. This gives
/// commands Session-level concurrency without violating libssh2's single-owner
/// requirement or letting a quiet/blocked command pin its peers.
nonisolated final class SSHConnectionWorker: @unchecked Sendable {
    private final class StableCString: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<CChar>
        let count: Int

        init(_ data: Data) {
            let bytes = Array(data)
            count = bytes.count
            pointer = .allocate(capacity: count + 1)
            for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
            pointer[count] = 0
        }

        deinit { pointer.deallocate() }
    }

    private final class SSHExecChannel: @unchecked Sendable {
        enum Phase { case opening, starting, running, closing, freeing }

        let id = UUID()
        let command: StableCString
        let cancellation: TransferCancellationToken
        let deadline: ContinuousClock.Instant
        let outputLimit: Int
        let onOutput: SSHExecOutputHandler?
        let continuation: CheckedContinuation<SSHExecResult, any Error>
        let channelLease: SSHChannelLease
        let input = SSHByteQueue(chunkSize: 32_700, zeroizesConsumedBytes: true)
        var phase = Phase.opening
        var execChannel: OpaquePointer?
        var sentEOF = false
        var stdout = Data()
        var stderr = Data()
        var stdoutRemoteBytes = 0
        var stderrRemoteBytes = 0
        let stdoutDecoder: RemoteCharsetStreamConverter
        let stderrDecoder: RemoteCharsetStreamConverter
        let charset: RemoteCharset
        var stdoutTruncated = false
        var stderrTruncated = false
        var terminalError: (any Error)?
        var exitCode: Int32 = 0
        var signal: String?
        var started = false
        var completed = false

        init(
            command: String, workingDirectory: String?, stdin: SSHCommandInput?, charset: RemoteCharset,
            timeout: TimeInterval,
            outputLimit: Int, cancellation: TransferCancellationToken,
            onOutput: SSHExecOutputHandler?, channelLease: SSHChannelLease,
            continuation: CheckedContinuation<SSHExecResult, any Error>
        ) throws {
            let effective: String
            if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
                effective = "cd -- \(Self.shellQuote(cwd)) && /bin/sh -lc \(Self.shellQuote(command))"
            } else {
                effective = "/bin/sh -lc \(Self.shellQuote(command))"
            }
            self.command = StableCString(
                try RemoteCharsetStreamConverter.encode(effective, charset: charset))
            self.charset = charset
            stdoutDecoder = try RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
            stderrDecoder = try RemoteCharsetStreamConverter(charset: charset, direction: .decoding)
            self.cancellation = cancellation
            deadline = .now.advanced(by: .seconds(max(1, min(timeout, 15 * 60))))
            self.outputLimit = outputLimit
            self.onOutput = onOutput
            self.channelLease = channelLease
            self.continuation = continuation
            try stdin?.append(to: input, charset: charset)
            sentEOF = input.isEmpty
        }

        private static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.connection")
    private let logger: Logger
    private let maxSessionsPolicy: SSHMaxSessionsPolicy
    private var connection: SSHAuthenticatedConnection?
    private var buffer: SSHConnectionBuffer?
    private var channelBudget: SSHChannelBudget?
    private var socketEvents: SSHSocketEvents?
    private var timer: (any DispatchSourceTimer)?
    private var hostID: UUID?
    private var charset: RemoteCharset = .utf8
    private var commands: [UUID: SSHExecChannel] = [:]
    private var pendingOpens = SSHReadyQueue<UUID>()
    private var opening: SSHExecChannel?
    private var ready = SSHReadyQueue<UUID>()
    private var scheduled = false
    private var generation = 0
    private var controlDirections: Int32 = 0
    private var keepaliveDue = true
    private var nextKeepalive = DispatchTime.now()
    private var scratch = [CChar](repeating: 0, count: 16 * 1024)
    private var sftpChannelOwner: SSHMultiplexedSFTPChannelOwner!
    private var connectionFailure: (@Sendable (String) -> Void)?
    private var didReportConnectionFailure = false

    init(logger: Logger, maxSessionsPolicy: SSHMaxSessionsPolicy) {
        self.logger = logger
        self.maxSessionsPolicy = maxSessionsPolicy
        sftpChannelOwner = SSHMultiplexedSFTPChannelOwner(
            queue: queue,
            context: { [weak self] in
                guard let self, let connection = self.connection,
                    let buffer = self.buffer,
                    let channelBudget = self.channelBudget
                else { return nil }
                return .init(
                    connection: connection, buffer: buffer,
                    channelBudget: channelBudget, charset: self.charset)
            },
            updateEvents: { [weak self] session, buffer in
                self?.updateSharedConnectionEvents(session: session, buffer: buffer)
            })
    }

    deinit {
        queue.sync { cleanup(error: CancellationError()) }
    }

    func connect(
        using request: SSHConnectionRequest,
        progress: SSHRouteProgressHandler? = nil,
        connectionFailure: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let operationID = UUID().uuidString.lowercased()
        let hostID = request.configuration.hostID
        logger.info(
            "ssh.multiplexed.connect.started",
            metadata: [
                "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "connecting",
            ])
        await disconnect()
        do {
            let opened = try await SSHConnectionOpener.openAuthenticatedConnection(
                using: request, timeout: 20, progress: progress, logger: logger)
            let channelBudget = maxSessionsPolicy.makeBudget()
            try await queue.perform {
                try Task.checkCancellation()
                self.connection = opened
                self.hostID = hostID
                self.charset = request.configuration.charset
                self.buffer = opened.installBuffer()
                self.channelBudget = channelBudget
                self.connectionFailure = connectionFailure
                self.didReportConnectionFailure = false
                libssh2_session_set_blocking(opened.libssh2Session, 0)
                libssh2_keepalive_config(opened.libssh2Session, 0, 30)
                self.startEvents(socket: opened.byteTransport.socket)
            }
            try Task.checkCancellation()
            logger.info(
                "ssh.multiplexed.connect.completed",
                metadata: [
                    "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                    "outcome": "success", "protocol": "ssh", "stage": "connected",
                ])
        } catch {
            await disconnect()
            logger.error(
                "ssh.multiplexed.connect.failed",
                metadata: [
                    "error_code": RemoteLogging.errorCode(error), "host_id": RemoteLogging.hostID(hostID),
                    "operation_id": "\(operationID)", "outcome": "failure", "protocol": "ssh",
                    "stage": "connecting",
                ])
            throw error
        }
    }

    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?, timeout: TimeInterval,
        outputLimit: Int, cancellation: TransferCancellationToken, onOutput: SSHExecOutputHandler?
    ) async throws -> SSHExecResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TermindSSHError.library("The command is empty.")
        }
        let operationID = UUID().uuidString.lowercased()
        var metadata: Logger.Metadata = [
            "operation_id": "\(operationID)", "protocol": "ssh", "stage": "executing",
        ]
        if let hostID = try? await queue.perform({ self.hostID }) {
            metadata["host_id"] = RemoteLogging.hostID(hostID)
        }
        logger.debug("ssh.exec.started", metadata: metadata)
        do {
            guard let channelBudget = try await queue.perform({ self.channelBudget }) else {
                throw SSHCommandExecutionError.connectionUnavailable(TermindSSHError.disconnected)
            }
            let channelLease = try await channelBudget.acquire(cancellation: cancellation)
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SSHExecResult, any Error>) in
                queue.async { [self] in
                    guard connection != nil, self.channelBudget === channelBudget else {
                        channelLease.release()
                        continuation.resume(
                            throwing: SSHCommandExecutionError.connectionUnavailable(TermindSSHError.disconnected))
                        return
                    }
                    let context: SSHExecChannel
                    do {
                        context = try SSHExecChannel(
                            command: command, workingDirectory: workingDirectory, stdin: stdin, charset: charset,
                            timeout: timeout, outputLimit: outputLimit, cancellation: cancellation,
                            onOutput: onOutput, channelLease: channelLease, continuation: continuation)
                    } catch {
                        channelLease.release()
                        continuation.resume(throwing: error)
                        return
                    }
                    commands[context.id] = context
                    pendingOpens.insert(context.id)
                    schedulePump()
                }
            }
            metadata["outcome"] = "success"
            metadata["stage"] = "completed"
            logger.debug("ssh.exec.completed", metadata: metadata)
            return result
        } catch {
            metadata["error_code"] = RemoteLogging.errorCode(error)
            metadata["outcome"] = "failure"
            logger.error("ssh.exec.failed", metadata: metadata)
            throw error
        }
    }

    func openSFTPChannel() async throws -> any SFTPChannelProtocol {
        try await sftpChannelOwner.openChannel()
    }

    private func updateSharedConnectionEvents(session: OpaquePointer, buffer: SSHConnectionBuffer) {
        let directions = libssh2_session_block_directions(session)
        socketEvents?.update(
            read: !buffer.isBackpressured,
            write: buffer.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cleanup(error: CancellationError())
                continuation.resume()
            }
        }
    }

    private func startEvents(socket: Int32) {
        generation += 1
        let token = generation
        socketEvents = SSHSocketEvents(socket: socket, queue: queue) { [weak self] in
            guard let self, self.generation == token else { return }
            self.wakeAll()
        }
        socketEvents?.update(read: false, write: false)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if DispatchTime.now() >= self.nextKeepalive { self.keepaliveDue = true }
            self.wakeAll()
        }
        timer = source
        source.resume()
        keepaliveDue = true
    }

    private func wakeAll() {
        for id in commands.keys { ready.insert(id) }
        schedulePump()
    }

    private func schedulePump() {
        guard connection != nil, !scheduled else { return }
        scheduled = true
        let token = generation
        queue.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard let connection, let buffer else { return }
        let session = connection.libssh2Session
        let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
        buffer.beginPass(deadline: deadline)
        do { try buffer.flush(socket: connection.byteTransport.socket) } catch {
            failConnection(session)
            return
        }
        if buffer.isBackpressured {
            socketEvents?.update(read: false, write: true)
            return
        }
        controlDirections = 0
        var progressed = advanceOpen(session)
        while !buffer.isBackpressured,
            DispatchTime.now().uptimeNanoseconds < deadline,
            let id = ready.pop()
        {
            guard let command = commands[id] else { continue }
            if advance(command, session: session, deadline: deadline) { progressed = true }
        }
        if advanceOpen(session) { progressed = true }
        if keepaliveDue {
            var next: Int32 = 0
            let result = libssh2_keepalive_send(session, &next)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
            } else if result < 0 {
                failConnection(session)
                return
            } else {
                keepaliveDue = false
                nextKeepalive = .now() + .seconds(max(1, Int(next)))
                progressed = true
            }
        }
        do { try buffer.flush(socket: connection.byteTransport.socket) } catch {
            failConnection(session)
            return
        }
        var byte: UInt8 = 0
        let available = Darwin.recv(connection.byteTransport.socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if available == 0 || (available < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            failConnection(session)
            return
        }
        let directions = commands.values.reduce(controlDirections) { partial, command in
            guard command.execChannel != nil else { return partial }
            return partial | libssh2_session_block_directions(session)
        }
        socketEvents?.update(
            read: !commands.isEmpty && !buffer.isBackpressured,
            write: buffer.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
        if progressed || buffer.exhaustedReadBudget { wakeAll() }
    }

    private func advanceOpen(_ session: OpaquePointer) -> Bool {
        if opening == nil {
            while let id = pendingOpens.pop() {
                if let command = commands[id], command.phase == .opening {
                    opening = command
                    break
                }
            }
        }
        guard let command = opening else { return false }
        if cancellationError(for: command) != nil {
            opening = nil
            finish(command, throwing: cancellationError(for: command)!)
            return true
        }
        guard
            let execChannel = libssh2_channel_open_ex(
                session, "session", 7, 2 * 1_024 * 1_024, 32 * 1_024, nil, 0)
        else {
            let code = libssh2_session_last_errno(session)
            if code == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            opening = nil
            let error = SSHConnectionOpener.connectionError(session, prefix: "Unable to open SSH exec Channel")
            if isConnectionError(code) {
                failConnection(session, error: error)
            } else {
                finish(command, throwing: SSHCommandExecutionError.channelUnavailable(error))
            }
            return true
        }
        opening = nil
        command.execChannel = execChannel
        command.phase = .starting
        ready.insert(command.id)
        return true
    }

    private func advance(_ command: SSHExecChannel, session: OpaquePointer, deadline: UInt64) -> Bool {
        if let cancellation = cancellationError(for: command), command.terminalError == nil {
            command.terminalError = cancellation
            if command.execChannel == nil {
                finish(command, throwing: cancellation)
                return true
            }
            command.phase = .closing
        }
        guard let execChannel = command.execChannel else { return false }
        switch command.phase {
        case .opening:
            return false
        case .starting:
            let result = libssh2_channel_process_startup(
                execChannel, "exec", 4, command.command.pointer, UInt32(command.command.count))
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            guard result == 0 else {
                let code = libssh2_session_last_errno(session)
                let error = SSHConnectionOpener.connectionError(session, prefix: "Unable to start remote command")
                command.terminalError = SSHCommandExecutionError.channelUnavailable(error)
                command.phase = .closing
                if isConnectionError(code) { failConnection(session, error: error) }
                ready.insert(command.id)
                return true
            }
            command.started = true
            command.phase = .running
            ready.insert(command.id)
            return true
        case .running:
            return advanceRunning(command, execChannel: execChannel, session: session, deadline: deadline)
        case .closing:
            let result = libssh2_channel_close(execChannel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            if command.terminalError == nil {
                command.exitCode = libssh2_channel_get_exit_status(execChannel)
                command.signal = exitSignal(execChannel: execChannel, session: session)
            }
            command.phase = .freeing
            ready.insert(command.id)
            return true
        case .freeing:
            let result = libssh2_channel_free(execChannel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            command.execChannel = nil
            if let error = command.terminalError {
                finish(command, throwing: error)
            } else {
                guard let stdout = String(data: command.stdout, encoding: .utf8),
                    let stderr = String(data: command.stderr, encoding: .utf8)
                else {
                    finish(
                        command,
                        throwing: RemoteCharsetConversionError(
                            charset: command.charset, direction: .decoding))
                    return true
                }
                finish(
                    command,
                    returning: SSHExecResult(
                        stdout: stdout, stderr: stderr,
                        exitCode: command.exitCode, signal: command.signal,
                        stdoutTruncated: command.stdoutTruncated,
                        stderrTruncated: command.stderrTruncated))
            }
            return true
        }
    }

    private func advanceRunning(
        _ command: SSHExecChannel, execChannel: OpaquePointer, session: OpaquePointer, deadline: UInt64
    ) -> Bool {
        var progressed = false
        var remaining = SSHForwardingTuning.current.quantum
        if !command.input.isEmpty {
            let written = command.input.withFirstBytes {
                libssh2_channel_write_ex(
                    execChannel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
            }
            if written > 0 {
                command.input.consume(written)
                remaining -= min(remaining, written)
                progressed = true
            } else if written == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
            } else {
                return fail(command, session: session, prefix: "Unable to write command input")
            }
        }
        if command.input.isEmpty, !command.sentEOF {
            let result = libssh2_channel_send_eof(execChannel)
            if result == 0 {
                command.sentEOF = true
                progressed = true
            } else if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
            } else {
                return fail(command, session: session, prefix: "Unable to finish command input")
            }
        }
        for stream in [Int32(0), Int32(1)] {
            while remaining > 0 && DispatchTime.now().uptimeNanoseconds < deadline {
                let capacity = min(scratch.count, remaining)
                let count = libssh2_channel_read_ex(execChannel, stream, &scratch, capacity)
                if count > 0 {
                    progressed = true
                    remaining -= count
                    let chunk = Data(bytes: scratch, count: count)
                    do {
                        try appendDecoded(chunk, stream: stream, to: command)
                    } catch {
                        command.terminalError = error
                        command.phase = .closing
                        ready.insert(command.id)
                        return true
                    }
                } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                    if count == LIBSSH2_ERROR_EAGAIN { blocked(session) }
                    break
                } else {
                    return fail(command, session: session, prefix: "Unable to read command output")
                }
            }
        }
        if libssh2_channel_eof(execChannel) == 1 {
            do {
                try finishDecodedOutput(command)
            } catch {
                command.terminalError = error
            }
            command.phase = .closing
            ready.insert(command.id)
            return true
        }
        if !command.input.isEmpty || !command.sentEOF || libssh2_poll_channel_read(execChannel, 0) == 1 {
            ready.insert(command.id)
        }
        return progressed
    }

    private func appendDecoded(_ chunk: Data, stream: Int32, to command: SSHExecChannel) throws {
        let isError = stream != 0
        let consumed = isError ? command.stderrRemoteBytes : command.stdoutRemoteBytes
        let available = max(0, command.outputLimit - consumed)
        let accepted = Data(chunk.prefix(available))
        if isError {
            command.stderrRemoteBytes += accepted.count
            if accepted.count < chunk.count { command.stderrTruncated = true }
        } else {
            command.stdoutRemoteBytes += accepted.count
            if accepted.count < chunk.count { command.stdoutTruncated = true }
        }
        guard !accepted.isEmpty else { return }
        let decoded = try (isError ? command.stderrDecoder : command.stdoutDecoder).convert(accepted).data
        guard !decoded.isEmpty else { return }
        command.onOutput?(decoded, isError)
        if isError { command.stderr.append(decoded) } else { command.stdout.append(decoded) }
    }

    private func finishDecodedOutput(_ command: SSHExecChannel) throws {
        if !command.stdoutTruncated {
            let tail = try command.stdoutDecoder.finish().data
            if !tail.isEmpty {
                command.onOutput?(tail, false)
                command.stdout.append(tail)
            }
        }
        if !command.stderrTruncated {
            let tail = try command.stderrDecoder.finish().data
            if !tail.isEmpty {
                command.onOutput?(tail, true)
                command.stderr.append(tail)
            }
        }
    }

    private func fail(_ command: SSHExecChannel, session: OpaquePointer, prefix: String) -> Bool {
        let code = libssh2_session_last_errno(session)
        let error = SSHConnectionOpener.connectionError(session, prefix: prefix)
        if isConnectionError(code) {
            failConnection(session, error: error)
        } else {
            command.terminalError = error
            command.phase = .closing
            ready.insert(command.id)
        }
        return true
    }

    private func cancellationError(for command: SSHExecChannel) -> (any Error)? {
        if command.cancellation.isCancelled { return CancellationError() }
        if ContinuousClock.now >= command.deadline {
            return TermindSSHError.library("The remote command timed out.")
        }
        return nil
    }

    private func exitSignal(execChannel: OpaquePointer, session: OpaquePointer) -> String? {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        let result = libssh2_channel_get_exit_signal(execChannel, &pointer, &length, nil, nil, nil, nil)
        guard result == 0, let pointer else { return nil }
        defer { libssh2_free(session, pointer) }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: length).map(UInt8.init(bitPattern:)),
            as: UTF8.self)
    }

    private func finish(_ command: SSHExecChannel, returning result: SSHExecResult) {
        guard !command.completed else { return }
        command.completed = true
        commands[command.id] = nil
        command.continuation.resume(returning: result)
    }

    private func finish(_ command: SSHExecChannel, throwing error: any Error) {
        guard !command.completed else { return }
        command.completed = true
        commands[command.id] = nil
        command.continuation.resume(throwing: error)
    }

    private func blocked(_ session: OpaquePointer) {
        controlDirections |= libssh2_session_block_directions(session)
    }

    private func isConnectionError(_ code: Int32) -> Bool {
        [
            LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT,
            LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_BAD_SOCKET,
        ].contains(code)
    }

    private func failConnection(_ session: OpaquePointer, error: (any Error)? = nil) {
        let failure = error ?? SSHConnectionOpener.connectionError(session, prefix: "The SSH connection closed")
        if !didReportConnectionFailure {
            didReportConnectionFailure = true
            connectionFailure?(failure.localizedDescription)
        }
        cleanup(error: failure)
    }

    private func cleanup(error: any Error) {
        generation += 1
        scheduled = false
        timer?.cancel()
        timer = nil
        for command in Array(commands.values) { finish(command, throwing: error) }
        commands.removeAll()
        opening = nil
        pendingOpens = SSHReadyQueue()
        ready = SSHReadyQueue()
        sftpChannelOwner.closeAllOnQueue()
        channelBudget?.close()
        channelBudget = nil
        let connection = connection
        self.connection = nil
        buffer = nil
        connectionFailure = nil
        didReportConnectionFailure = false
        hostID = nil
        if let events = socketEvents {
            events.cancel { connection?.close() }
            socketEvents = nil
        } else {
            connection?.close()
        }
    }

}

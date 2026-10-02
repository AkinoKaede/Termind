import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

/// Shared exec state machines. All libssh2 calls run on the enclosing connection's queue.
nonisolated final class SSHMultiplexedExecChannelOwner: @unchecked Sendable {
    struct Context: @unchecked Sendable {
        var connection: SSHAuthenticatedConnection
        var buffer: SSHConnectionBuffer
        var channelBudget: SSHChannelBudget
        var charset: RemoteCharset
        var hostID: UUID?
    }
    private let queue: DispatchQueue
    private let logger: Logger
    private let context: @Sendable () -> Context?
    private let schedulePump: @Sendable () -> Void
    private let connectionFailed: @Sendable (any Error) -> Void
    private let didCloseLastChannel: @Sendable () -> Void
    private let requestsAgentForwarding: Bool
    private var buffer: SSHConnectionBuffer? { context()?.buffer }
    private var charset: RemoteCharset { context()?.charset ?? .utf8 }
    private var isClosingAll = false
    private var commands: [UUID: SSHExecChannel] = [:]
    private var pendingOpens = SSHReadyQueue<UUID>()
    private var opening: SSHExecChannel?
    private var ready = SSHReadyQueue<UUID>()
    private var scratch = [CChar](repeating: 0, count: 16 * 1024)
    private(set) var controlDirections: Int32 = 0
    var isEmptyOnQueue: Bool { commands.isEmpty }

    init(
        queue: DispatchQueue, logger: Logger, requestsAgentForwarding: Bool = true,
        context: @escaping @Sendable () -> Context?,
        schedulePump: @escaping @Sendable () -> Void,
        connectionFailed: @escaping @Sendable (any Error) -> Void,
        didCloseLastChannel: @escaping @Sendable () -> Void = {}
    ) {
        self.queue = queue
        self.logger = logger
        self.requestsAgentForwarding = requestsAgentForwarding
        self.context = context
        self.schedulePump = schedulePump
        self.connectionFailed = connectionFailed
        self.didCloseLastChannel = didCloseLastChannel
    }

    func wakeAllOnQueue() {
        for id in commands.keys { ready.insert(id) }
    }

    func advanceOnQueue(deadline: UInt64) -> Bool {
        guard let context = context() else { return false }
        controlDirections = 0
        let session = context.connection.libssh2Session
        var progressed = advanceOpen(session)
        while !context.buffer.isBackpressured, DispatchTime.now().uptimeNanoseconds < deadline,
            let id = ready.pop()
        {
            guard let command = commands[id] else { continue }
            if advance(command, session: session, deadline: deadline) { progressed = true }
        }
        if self.context() != nil, advanceOpen(session) { progressed = true }
        return progressed
    }

    func cancelAllOnQueue() {
        for command in commands.values { command.cancellation.cancel() }
        wakeAllOnQueue()
    }

    func closeAllOnQueue(error: any Error) {
        isClosingAll = true
        defer { isClosingAll = false }
        for command in Array(commands.values) { finish(command, throwing: error) }
        commands.removeAll()
        opening = nil
        pendingOpens = SSHReadyQueue()
        ready = SSHReadyQueue()
        agentForwardingRequested = false
        agentRequestOwner = nil
    }

    private func failConnection(_ session: OpaquePointer, error: (any Error)? = nil) {
        connectionFailed(error ?? SSHConnectionOpener.connectionError(session, prefix: "The SSH connection closed"))
    }

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

    private var agentForwardingRequested = false
    private var agentRequestOwner: UUID?

    private final class SSHExecChannel: @unchecked Sendable {
        enum Phase { case opening, forwarding, starting, running, closing, freeing }

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
            usesLoginShell: Bool,
            timeout: TimeInterval,
            outputLimit: Int, cancellation: TransferCancellationToken,
            onOutput: SSHExecOutputHandler?, channelLease: SSHChannelLease,
            continuation: CheckedContinuation<SSHExecResult, any Error>
        ) throws {
            let shellFlags = usesLoginShell ? "-lc" : "-c"
            let effective: String
            if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
                effective = "cd -- \(Self.shellQuote(cwd)) && /bin/sh \(shellFlags) \(Self.shellQuote(command))"
            } else {
                effective = "/bin/sh \(shellFlags) \(Self.shellQuote(command))"
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

    func execute(
        _ command: String, workingDirectory: String?, stdin: SSHCommandInput?, timeout: TimeInterval,
        outputLimit: Int, cancellation: TransferCancellationToken, onOutput: SSHExecOutputHandler?,
        usesLoginShell: Bool = true
    ) async throws -> SSHExecResult {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TermindSSHError.library("The command is empty.")
        }
        let operationID = UUID().uuidString.lowercased()
        var metadata: Logger.Metadata = [
            "operation_id": "\(operationID)", "protocol": "ssh", "stage": "executing",
        ]
        if let hostID = try? await queue.perform({ self.context()?.hostID }) {
            metadata["host_id"] = RemoteLogging.hostID(hostID)
        }
        logger.debug("ssh.exec.started", metadata: metadata)
        do {
            guard let channelBudget = try await queue.perform({ self.context()?.channelBudget }) else {
                throw SSHCommandExecutionError.connectionUnavailable(TermindSSHError.disconnected)
            }
            let channelLease = try await channelBudget.acquire(cancellation: cancellation)
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SSHExecResult, any Error>) in
                queue.async { [self] in
                    guard self.context() != nil, self.context()?.channelBudget === channelBudget else {
                        channelLease.release()
                        continuation.resume(
                            throwing: SSHCommandExecutionError.connectionUnavailable(TermindSSHError.disconnected))
                        return
                    }
                    let context: SSHExecChannel
                    do {
                        context = try SSHExecChannel(
                            command: command, workingDirectory: workingDirectory, stdin: stdin, charset: charset,
                            usesLoginShell: usesLoginShell,
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
        command.phase = requestsAgentForwarding && buffer?.agentChannels != nil ? .forwarding : .starting
        ready.insert(command.id)
        return true
    }

    private func advance(_ command: SSHExecChannel, session: OpaquePointer, deadline: UInt64) -> Bool {
        // Release the caller promptly on cancellation/timeout; retain the channel and its
        // lease until the nonblocking close/free state machine finishes on this queue.
        if let cancellation = cancellationError(for: command), !command.completed {
            command.completed = true
            command.continuation.resume(throwing: command.terminalError ?? cancellation)
        }
        if let cancellation = cancellationError(for: command), command.terminalError == nil {
            if agentRequestOwner == command.id {
                // A cancelled, unanswered connection-wide request cannot safely
                // be repeated on another channel: the peer may already have accepted it.
                failConnection(session, error: cancellation)
                return false
            }
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
        case .forwarding:
            if agentForwardingRequested {
                command.phase = .starting
                ready.insert(command.id)
                return true
            }
            guard agentRequestOwner == nil || agentRequestOwner == command.id else { return false }
            agentRequestOwner = command.id
            let result = libssh2_channel_request_auth_agent(execChannel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            agentRequestOwner = nil
            if result != 0 {
                command.terminalError = SSHCommandExecutionError.channelUnavailable(
                    SSHConnectionOpener.connectionError(session, prefix: "Agent Forwarding request failed"))
                command.phase = .closing
            } else {
                agentForwardingRequested = true
                command.phase = .starting
            }
            ready.insert(command.id)
            return true
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
                let stdout = String(decoding: command.stdout, as: UTF8.self)
                let stderr = String(decoding: command.stderr, as: UTF8.self)
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
        commands[command.id] = nil
        if !command.completed {
            command.completed = true
            command.continuation.resume(returning: result)
        }
        if commands.isEmpty, !isClosingAll { didCloseLastChannel() }
    }

    private func finish(_ command: SSHExecChannel, throwing error: any Error) {
        commands[command.id] = nil
        if !command.completed {
            command.completed = true
            command.continuation.resume(throwing: error)
        }
        if commands.isEmpty, !isClosingAll { didCloseLastChannel() }
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

}

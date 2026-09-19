import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication

/// One authenticated SSH transport with any number of non-PTY exec Channels.
///
/// libssh2 itself is never entered concurrently. Every call is made by `queue`,
/// while command state machines take bounded turns from `ready`. This gives
/// commands Channel-level concurrency without violating libssh2's single-owner
/// requirement or letting a quiet/blocked command pin its peers.
nonisolated final class SSHMultiplexedSessionWorker: @unchecked Sendable {
    private final class StableCString: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<CChar>
        let count: Int

        init(_ value: String) {
            let bytes = Array(value.utf8)
            count = bytes.count
            pointer = .allocate(capacity: count + 1)
            for (index, byte) in bytes.enumerated() { pointer[index] = CChar(bitPattern: byte) }
            pointer[count] = 0
        }

        deinit { pointer.deallocate() }
    }

    private final class Command: @unchecked Sendable {
        enum Phase { case opening, starting, running, closing, freeing }

        let id = UUID()
        let command: StableCString
        let cancellation: TransferCancellationToken
        let deadline: ContinuousClock.Instant
        let outputLimit: Int
        let onOutput: SSHExecOutputHandler?
        let continuation: CheckedContinuation<SSHExecResult, any Error>
        let input = SSHByteQueue(chunkSize: 32_700)
        var phase = Phase.opening
        var channel: OpaquePointer?
        var sentEOF = false
        var stdout = Data()
        var stderr = Data()
        var stdoutTruncated = false
        var stderrTruncated = false
        var terminalError: (any Error)?
        var exitCode: Int32 = 0
        var signal: String?
        var started = false
        var completed = false

        init(
            command: String, workingDirectory: String?, stdin: Data?, timeout: TimeInterval,
            outputLimit: Int, cancellation: TransferCancellationToken,
            onOutput: SSHExecOutputHandler?, continuation: CheckedContinuation<SSHExecResult, any Error>
        ) {
            let effective: String
            if let cwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty {
                effective = "cd -- \(Self.shellQuote(cwd)) && /bin/sh -lc \(Self.shellQuote(command))"
            } else {
                effective = "/bin/sh -lc \(Self.shellQuote(command))"
            }
            self.command = StableCString(effective)
            self.cancellation = cancellation
            deadline = .now.advanced(by: .seconds(max(1, min(timeout, 15 * 60))))
            self.outputLimit = outputLimit
            self.onOutput = onOutput
            self.continuation = continuation
            var input = stdin ?? Data()
            if !input.isEmpty, input.last != 0x0A { input.append(0x0A) }
            self.input.append(input)
            sentEOF = input.isEmpty
        }

        private static func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
    }

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.exec-multiplexer")
    private let logger: Logger
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var bufferedTransport: SSHBufferedTransport?
    private var socketEvents: SSHSocketEvents?
    private var timer: (any DispatchSourceTimer)?
    private var hostID: UUID?
    private var commands: [UUID: Command] = [:]
    private var pendingOpens = SSHReadyQueue<UUID>()
    private var opening: Command?
    private var ready = SSHReadyQueue<UUID>()
    private var scheduled = false
    private var generation = 0
    private var controlDirections: Int32 = 0
    private var keepaliveDue = true
    private var nextKeepalive = DispatchTime.now()
    private var scratch = [CChar](repeating: 0, count: 16 * 1024)
    private var sftpChannels: [UUID: OpaquePointer] = [:]
    private var sftpOpening = false
    private var sftpOpenWaiters: [CheckedContinuation<Void, Never>] = []
    private let sharedSFTPIdentity = UUID()

    init(logger: Logger) { self.logger = logger }

    deinit {
        queue.sync { cleanup(error: CancellationError()) }
    }

    func connect(using request: SSHConnectionRequest) async throws {
        let operationID = UUID().uuidString.lowercased()
        let hostID = request.configuration.hostID
        logger.info(
            "ssh.exec.connect.started",
            metadata: [
                "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "connecting",
            ])
        await disconnect()
        do {
            let opened = try await SSHSessionWorker.openAuthenticatedSession(
                using: request, timeout: 20, logger: logger)
            try await queue.perform {
                try Task.checkCancellation()
                self.routeTransport = opened.transport
                self.session = opened.session
                self.hostID = hostID
                self.bufferedTransport = SSHBufferedTransport(session: opened.session)
                libssh2_session_set_blocking(opened.session, 0)
                libssh2_keepalive_config(opened.session, 0, 30)
                self.startEvents(socket: opened.transport.socket)
            }
            try Task.checkCancellation()
            logger.info(
                "ssh.exec.connect.completed",
                metadata: [
                    "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                    "outcome": "success", "protocol": "ssh", "stage": "connected",
                ])
        } catch {
            await disconnect()
            logger.error(
                "ssh.exec.connect.failed",
                metadata: [
                    "error_code": RemoteLogging.errorCode(error), "host_id": RemoteLogging.hostID(hostID),
                    "operation_id": "\(operationID)", "outcome": "failure", "protocol": "ssh",
                    "stage": "connecting",
                ])
            throw error
        }
    }

    func execute(
        _ command: String, workingDirectory: String?, stdin: Data?, timeout: TimeInterval,
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
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SSHExecResult, any Error>) in
                queue.async { [self] in
                    guard session != nil else {
                        continuation.resume(
                            throwing: SSHExecSessionError.transportUnavailable(TermindSSHError.disconnected))
                        return
                    }
                    let context = Command(
                        command: command, workingDirectory: workingDirectory, stdin: stdin,
                        timeout: timeout, outputLimit: outputLimit, cancellation: cancellation,
                        onOutput: onOutput, continuation: continuation)
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

    func openSFTPChannel() async throws -> any SFTPClientProtocol {
        let driver = SSHSharedSFTPDriver(
            identity: sharedSFTPIdentity,
            open: { [weak self] in
                guard let self else { throw SFTPError.notConnected }
                return try await self.openRawSFTPChannel()
            },
            close: { [weak self] id in await self?.closeSFTPChannel(id) },
            perform: { [weak self] id, operation in
                guard let self else { throw SFTPError.notConnected }
                return try await self.performSharedSFTP(id, operation)
            })
        return try await SSHSharedSFTPClient.open(using: driver)
    }

    private func openRawSFTPChannel() async throws -> UUID {
        await reserveSFTPOpen()
        defer { releaseSFTPOpen() }
        let id = UUID()
        while true {
            try Task.checkCancellation()
            let attempt: SSHSharedSFTPAttempt<Void> = try await queue.perform { [self] in
                guard let session, let bufferedTransport, let routeTransport else {
                    throw SFTPError.notConnected
                }
                let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
                bufferedTransport.beginPass(deadline: deadline)
                try bufferedTransport.flush(socket: routeTransport.socket)
                if bufferedTransport.isBackpressured { return .again }
                guard let sftp = libssh2_sftp_init(session) else {
                    if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN { return .again }
                    throw SSHSessionWorker.sessionError(session, prefix: "Unable to start SFTP")
                }
                sftpChannels[id] = sftp
                try bufferedTransport.flush(socket: routeTransport.socket)
                updateSharedTransportEvents(session: session, transport: bufferedTransport)
                return .value(())
            }
            if case .value = attempt { return id }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func reserveSFTPOpen() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if sftpOpening {
                    sftpOpenWaiters.append(continuation)
                } else {
                    sftpOpening = true
                    continuation.resume()
                }
            }
        }
    }

    private func releaseSFTPOpen() {
        queue.async { [self] in
            if sftpOpenWaiters.isEmpty {
                sftpOpening = false
            } else {
                sftpOpenWaiters.removeFirst().resume()
            }
        }
    }

    private func closeSFTPChannel(_ id: UUID) async {
        while true {
            let attempt: SSHSharedSFTPAttempt<Void> =
                (try? await queue.perform { [self] in
                    guard let sftp = sftpChannels[id] else { return .value(()) }
                    guard let session, let bufferedTransport, let routeTransport else {
                        sftpChannels[id] = nil
                        return .value(())
                    }
                    let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
                    bufferedTransport.beginPass(deadline: deadline)
                    try bufferedTransport.flush(socket: routeTransport.socket)
                    let result = libssh2_sftp_shutdown(sftp)
                    if result == LIBSSH2_ERROR_EAGAIN { return .again }
                    sftpChannels[id] = nil
                    try bufferedTransport.flush(socket: routeTransport.socket)
                    updateSharedTransportEvents(session: session, transport: bufferedTransport)
                    return .value(())
                }) ?? .value(())
            if case .value = attempt { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func performSharedSFTP(
        _ id: UUID, _ operation: @escaping SSHSharedSFTPDriver.RawOperation
    ) async throws -> SSHSharedSFTPValue {
        while true {
            try Task.checkCancellation()
            let attempt = try await queue.perform { [self] in
                guard let session, let sftp = sftpChannels[id], let bufferedTransport, let routeTransport else {
                    throw SFTPError.notConnected
                }
                let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
                bufferedTransport.beginPass(deadline: deadline)
                try bufferedTransport.flush(socket: routeTransport.socket)
                if bufferedTransport.isBackpressured { return SSHSharedSFTPAnyAttempt.again }
                let result = try operation(session, sftp)
                try bufferedTransport.flush(socket: routeTransport.socket)
                updateSharedTransportEvents(session: session, transport: bufferedTransport)
                return result
            }
            switch attempt {
            case .value(let value): return value
            case .again: try await Task.sleep(for: .milliseconds(2))
            }
        }
    }

    private func updateSharedTransportEvents(session: OpaquePointer, transport: SSHBufferedTransport) {
        let directions = libssh2_session_block_directions(session)
        socketEvents?.update(
            read: !transport.isBackpressured,
            write: transport.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
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
        guard session != nil, !scheduled else { return }
        scheduled = true
        let token = generation
        queue.async { [weak self] in
            guard let self, self.generation == token else { return }
            self.scheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard let session, let bufferedTransport, let routeTransport else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
        bufferedTransport.beginPass(deadline: deadline)
        do { try bufferedTransport.flush(socket: routeTransport.socket) } catch {
            failTransport(session)
            return
        }
        if bufferedTransport.isBackpressured {
            socketEvents?.update(read: false, write: true)
            return
        }
        controlDirections = 0
        var progressed = advanceOpen(session)
        while !bufferedTransport.isBackpressured,
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
                failTransport(session)
                return
            } else {
                keepaliveDue = false
                nextKeepalive = .now() + .seconds(max(1, Int(next)))
                progressed = true
            }
        }
        do { try bufferedTransport.flush(socket: routeTransport.socket) } catch {
            failTransport(session)
            return
        }
        var byte: UInt8 = 0
        let available = Darwin.recv(routeTransport.socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if available == 0 || (available < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            failTransport(session)
            return
        }
        let directions = commands.values.reduce(controlDirections) { partial, command in
            guard command.channel != nil else { return partial }
            return partial | libssh2_session_block_directions(session)
        }
        socketEvents?.update(
            read: !commands.isEmpty && !bufferedTransport.isBackpressured,
            write: bufferedTransport.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
        if progressed || bufferedTransport.exhaustedReadBudget { wakeAll() }
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
            let channel = libssh2_channel_open_ex(
                session, "session", 7, 2 * 1_024 * 1_024, 32 * 1_024, nil, 0)
        else {
            let code = libssh2_session_last_errno(session)
            if code == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            opening = nil
            let error = SSHSessionWorker.sessionError(session, prefix: "Unable to open SSH exec channel")
            if isTransportError(code) {
                failTransport(session, error: error)
            } else {
                finish(command, throwing: SSHExecSessionError.channelUnavailable(error))
            }
            return true
        }
        opening = nil
        command.channel = channel
        command.phase = .starting
        ready.insert(command.id)
        return true
    }

    private func advance(_ command: Command, session: OpaquePointer, deadline: UInt64) -> Bool {
        if let cancellation = cancellationError(for: command), command.terminalError == nil {
            command.terminalError = cancellation
            if command.channel == nil {
                finish(command, throwing: cancellation)
                return true
            }
            command.phase = .closing
        }
        guard let channel = command.channel else { return false }
        switch command.phase {
        case .opening:
            return false
        case .starting:
            let result = libssh2_channel_process_startup(
                channel, "exec", 4, command.command.pointer, UInt32(command.command.count))
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            guard result == 0 else {
                let code = libssh2_session_last_errno(session)
                let error = SSHSessionWorker.sessionError(session, prefix: "Unable to start remote command")
                command.terminalError = SSHExecSessionError.channelUnavailable(error)
                command.phase = .closing
                if isTransportError(code) { failTransport(session, error: error) }
                ready.insert(command.id)
                return true
            }
            command.started = true
            command.phase = .running
            ready.insert(command.id)
            return true
        case .running:
            return advanceRunning(command, channel: channel, session: session, deadline: deadline)
        case .closing:
            let result = libssh2_channel_close(channel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            if command.terminalError == nil {
                command.exitCode = libssh2_channel_get_exit_status(channel)
                command.signal = exitSignal(channel: channel, session: session)
            }
            command.phase = .freeing
            ready.insert(command.id)
            return true
        case .freeing:
            let result = libssh2_channel_free(channel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            command.channel = nil
            if let error = command.terminalError {
                finish(command, throwing: error)
            } else {
                finish(
                    command,
                    returning: SSHExecResult(
                        stdout: String(decoding: command.stdout, as: UTF8.self),
                        stderr: String(decoding: command.stderr, as: UTF8.self),
                        exitCode: command.exitCode, signal: command.signal,
                        stdoutTruncated: command.stdoutTruncated,
                        stderrTruncated: command.stderrTruncated))
            }
            return true
        }
    }

    private func advanceRunning(
        _ command: Command, channel: OpaquePointer, session: OpaquePointer, deadline: UInt64
    ) -> Bool {
        var progressed = false
        var remaining = SSHForwardingTuning.current.quantum
        if !command.input.isEmpty {
            let written = command.input.withFirstBytes {
                libssh2_channel_write_ex(
                    channel, 0, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count)
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
            let result = libssh2_channel_send_eof(channel)
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
                let count = libssh2_channel_read_ex(channel, stream, &scratch, capacity)
                if count > 0 {
                    progressed = true
                    remaining -= count
                    let chunk = Data(bytes: scratch, count: count)
                    command.onOutput?(chunk, stream != 0)
                    if stream == 0 {
                        Self.appendCapped(
                            chunk, to: &command.stdout, limit: command.outputLimit,
                            truncated: &command.stdoutTruncated)
                    } else {
                        Self.appendCapped(
                            chunk, to: &command.stderr, limit: command.outputLimit,
                            truncated: &command.stderrTruncated)
                    }
                } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                    if count == LIBSSH2_ERROR_EAGAIN { blocked(session) }
                    break
                } else {
                    return fail(command, session: session, prefix: "Unable to read command output")
                }
            }
        }
        if libssh2_channel_eof(channel) == 1 {
            command.phase = .closing
            ready.insert(command.id)
            return true
        }
        if !command.input.isEmpty || !command.sentEOF || libssh2_poll_channel_read(channel, 0) == 1 {
            ready.insert(command.id)
        }
        return progressed
    }

    private func fail(_ command: Command, session: OpaquePointer, prefix: String) -> Bool {
        let code = libssh2_session_last_errno(session)
        let error = SSHSessionWorker.sessionError(session, prefix: prefix)
        if isTransportError(code) {
            failTransport(session, error: error)
        } else {
            command.terminalError = error
            command.phase = .closing
            ready.insert(command.id)
        }
        return true
    }

    private func cancellationError(for command: Command) -> (any Error)? {
        if command.cancellation.isCancelled { return CancellationError() }
        if ContinuousClock.now >= command.deadline {
            return TermindSSHError.library("The remote command timed out.")
        }
        return nil
    }

    private func exitSignal(channel: OpaquePointer, session: OpaquePointer) -> String? {
        var pointer: UnsafeMutablePointer<CChar>?
        var length = 0
        let result = libssh2_channel_get_exit_signal(channel, &pointer, &length, nil, nil, nil, nil)
        guard result == 0, let pointer else { return nil }
        defer { libssh2_free(session, pointer) }
        return String(
            decoding: UnsafeBufferPointer(start: pointer, count: length).map(UInt8.init(bitPattern:)),
            as: UTF8.self)
    }

    private func finish(_ command: Command, returning result: SSHExecResult) {
        guard !command.completed else { return }
        command.completed = true
        commands[command.id] = nil
        command.continuation.resume(returning: result)
    }

    private func finish(_ command: Command, throwing error: any Error) {
        guard !command.completed else { return }
        command.completed = true
        commands[command.id] = nil
        command.continuation.resume(throwing: error)
    }

    private func blocked(_ session: OpaquePointer) {
        controlDirections |= libssh2_session_block_directions(session)
    }

    private func isTransportError(_ code: Int32) -> Bool {
        [
            LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT,
            LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_BAD_SOCKET,
        ].contains(code)
    }

    private func failTransport(_ session: OpaquePointer, error: (any Error)? = nil) {
        let failure = error ?? SSHSessionWorker.sessionError(session, prefix: "The SSH connection closed")
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
        for sftp in sftpChannels.values { _ = libssh2_sftp_shutdown(sftp) }
        sftpChannels.removeAll()
        let transport = routeTransport
        routeTransport = nil
        if let session {
            if let bufferedTransport {
                bufferedTransport.dispose(session: session)
            } else {
                _ = libssh2_session_free(session)
            }
        }
        session = nil
        bufferedTransport = nil
        hostID = nil
        if let events = socketEvents {
            events.cancel { transport?.close() }
            socketEvents = nil
        } else {
            transport?.close()
        }
    }

    private static func appendCapped(
        _ chunk: Data, to destination: inout Data, limit: Int, truncated: inout Bool
    ) {
        let remaining = max(0, limit - destination.count)
        if chunk.count > remaining { truncated = true }
        if remaining > 0 { destination.append(chunk.prefix(remaining)) }
    }
}

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
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let logger: Logger
    private let maxSessionsPolicy: SSHMaxSessionsPolicy
    private var connection: SSHAuthenticatedConnection?
    private var buffer: SSHConnectionBuffer?
    private var channelBudget: SSHChannelBudget?
    private var socketEvents: SSHSocketEvents?
    private var timer: (any DispatchSourceTimer)?
    private var hostID: UUID?
    private var charset: RemoteCharset = .utf8
    private var accessCheck: HostOperationAccessCheck?
    private var scheduled = false
    private var generation = 0
    private var controlDirections: Int32 = 0
    private var keepaliveDue = true
    private var nextKeepalive = DispatchTime.now()
    private var execChannelOwner: SSHMultiplexedExecChannelOwner!
    private var sftpChannelOwner: SSHMultiplexedSFTPChannelOwner!
    private var connectionFailure: (@Sendable (String) -> Void)?
    private var didReportConnectionFailure = false

    init(
        logger: Logger, maxSessionsPolicy: SSHMaxSessionsPolicy,
        queue: DispatchQueue = DispatchQueue(label: "com.akinokaede.termind.ssh.connection")
    ) {
        self.queue = queue
        self.logger = logger
        self.maxSessionsPolicy = maxSessionsPolicy
        queue.setSpecific(key: queueKey, value: ())
        execChannelOwner = SSHMultiplexedExecChannelOwner(
            queue: queue, logger: logger,
            context: { [weak self] in
                guard let self, let connection = self.connection, let buffer = self.buffer,
                    let channelBudget = self.channelBudget
                else { return nil }
                return .init(
                    connection: connection, buffer: buffer, channelBudget: channelBudget,
                    charset: self.charset, hostID: self.hostID)
            },
            schedulePump: { [weak self] in self?.schedulePump() },
            connectionFailed: { [weak self] error in
                guard let self, let connection = self.connection else { return }
                self.failConnection(connection.libssh2Session, error: error)
            })
        sftpChannelOwner = SSHMultiplexedSFTPChannelOwner(
            queue: queue,
            context: { [weak self] in
                guard let self, let connection = self.connection,
                    let buffer = self.buffer,
                    let channelBudget = self.channelBudget
                else { return nil }
                return .init(
                    connection: connection, buffer: buffer,
                    channelBudget: channelBudget, charset: self.charset, accessCheck: self.accessCheck)
            },
            updateEvents: { [weak self] session, buffer in
                self?.updateSharedConnectionEvents(session: session, buffer: buffer)
            })
    }

    deinit {
        // A queued callback can release the last reference to this worker.
        // Cleanup must stay serialized without synchronously reentering its queue.
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            cleanup(error: CancellationError())
        } else {
            queue.sync { cleanup(error: CancellationError()) }
        }
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
            try await queue.perform { [self] in
                try Task.checkCancellation()
                self.connection = opened
                self.hostID = hostID
                self.charset = request.configuration.charset
                self.accessCheck = request.configuration.accessCheck
                self.buffer = opened.installBuffer()
                if let provider = request.agentForwarding {
                    self.buffer?.agentChannels = SSHAgentChannels(provider: provider, queue: self.queue) {
                        [weak self] in self?.wakeAll()
                    }
                    libssh2_session_callback_set2(
                        opened.libssh2Session, LIBSSH2_CALLBACK_AUTHAGENT,
                        unsafeBitCast(SSHAgentChannels.callback, to: (@convention(c) () -> Void).self))
                }
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
        try await queue.perform { [self] in try accessCheck?() }
        return try await execChannelOwner.execute(
            command, workingDirectory: workingDirectory, stdin: stdin,
            timeout: timeout, outputLimit: outputLimit, cancellation: cancellation, onOutput: onOutput)
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
        execChannelOwner.wakeAllOnQueue()
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
        var progressed =
            buffer.agentChannels?.advance(
                deadline: min(
                    deadline, DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds / 2),
                permitsIO: { !buffer.isBackpressured }) ?? false
        if execChannelOwner.advanceOnQueue(deadline: deadline) { progressed = true }
        if buffer.agentChannels?.advance(deadline: deadline, permitsIO: { !buffer.isBackpressured }) == true {
            progressed = true
        }
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
        let directions = controlDirections | execChannelOwner.controlDirections
        socketEvents?.update(
            read: !execChannelOwner.isEmptyOnQueue && !buffer.isBackpressured,
            write: buffer.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
        if progressed || buffer.exhaustedReadBudget { wakeAll() }
    }

    private func blocked(_ session: OpaquePointer) {
        controlDirections |= libssh2_session_block_directions(session)
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
        buffer?.agentChannels?.shutdown()
        generation += 1
        scheduled = false
        timer?.cancel()
        timer = nil
        execChannelOwner.closeAllOnQueue(error: error)
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

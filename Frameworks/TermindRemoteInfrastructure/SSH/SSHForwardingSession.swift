import CSSH2
import Darwin
import Foundation
import Logging
import TermindApplication
import TermindDomain

/// Queue-owned diagnostic totals for tests; excludes jump sessions and kernel/libssh2 buffers.
nonisolated struct SSHForwardingStatistics: Sendable {
    var passes = 0
    var plaintextSocketWriteCalls = 0
    var encryptedSocketWriteCalls = 0
    var peakPlaintextQueueBytes = 0
    var peakEncryptedQueueBytes = 0
}

public protocol SSHForwardingSessionProtocol: Actor {
    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws
    func start(_ rule: PortForwardingRule, generation: UUID) async throws
    func stop(_ id: PortForwardingRule.ID) async
    func disconnect() async
}

public actor SSHForwardingSession: SSHForwardingSessionProtocol {
    public nonisolated static let schedulingMode = SSHChannelSchedulingMode.channelsOnly

    public typealias ConnectionHandler = @Sendable (PortForwardingRule.ID, UUID, Int) -> Void
    public typealias FailureHandler = @Sendable (String) -> Void

    private let worker: SSHForwardingWorker

    public init(
        connectionHandler: @escaping ConnectionHandler,
        failureHandler: @escaping FailureHandler,
        logger: Logger = ApplicationLogger.disabled("termind.port-forwarding-session")
    ) {
        worker = SSHForwardingWorker(
            connectionHandler: connectionHandler, failureHandler: failureHandler, logger: logger
        )
    }

    public func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler? = nil) async throws {
        try await worker.connect(request, progress: progress)
    }

    public func start(_ rule: PortForwardingRule, generation: UUID = UUID()) async throws {
        try await worker.start(rule, generation: generation)
    }

    public func stop(_ id: PortForwardingRule.ID) async {
        await worker.stop(id)
    }

    public func disconnect() async {
        await worker.disconnect()
    }

    func statistics() async -> SSHForwardingStatistics { await worker.statistics() }
}

private nonisolated final class SSHForwardingWorker: @unchecked Sendable {
    private static let initialization: Void = {
        precondition(libssh2_init(0) == 0, "libssh2 initialization failed")
    }()

    private final class RuleContext: @unchecked Sendable {
        let rule: PortForwardingRule
        let generation: UUID
        var socket: Int32 = -1
        var events: SSHSocketEvents?
        var remoteListener: OpaquePointer?
        var flows: [UUID: Flow] = [:]
        var start: CheckedContinuation<Void, any Error>?
        var stopped = false
        var stop: (@Sendable () -> Void)?
        var reportedCount = -1

        init(rule: PortForwardingRule, generation: UUID) {
            self.rule = rule
            self.generation = generation
        }
    }

    private final class Flow: @unchecked Sendable {
        enum Phase { case greeting, request, opening, connecting, forwarding }
        let id = UUID()
        let context: RuleContext
        let stream: SSHStreamPump
        var phase: Phase
        var target: (String, Int)?
        var handshake = Data()
        var events: SSHSocketEvents?
        var connector: SSHForwardingConnector?
        var retired = false

        init(socket: Int32, context: RuleContext, channel: OpaquePointer? = nil) {
            self.context = context
            stream = SSHStreamPump(socket: socket, channel: channel)
            phase = context.rule.kind == .dynamic ? .greeting : channel == nil ? .opening : .connecting
            if let host = context.rule.targetHost, let port = context.rule.targetPort { target = (host, port) }
        }
    }

    private final class RetiredListener {
        let listener: OpaquePointer
        let completion: () -> Void
        init(_ listener: OpaquePointer, completion: @escaping () -> Void) {
            self.listener = listener
            self.completion = completion
        }
    }

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.forwarding")
    private let closingSockets = DispatchGroup()
    private let connectionHandler: SSHForwardingSession.ConnectionHandler
    private let failureHandler: SSHForwardingSession.FailureHandler
    private let logger: Logger
    private var socket: Int32 = -1
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var rules: [PortForwardingRule.ID: RuleContext] = [:]
    private var flows: [UUID: Flow] = [:]
    private var bufferedTransport: SSHBufferedTransport?
    private var transportEvents: SSHSocketEvents?
    private var timer: (any DispatchSourceTimer)?
    private var ready = SSHReadyQueue<UUID>()
    private var pendingOpens = SSHReadyQueue<UUID>()
    private var opening: Flow?
    private var pendingListeners: [RuleContext] = []
    private var listening: RuleContext?
    private var retiredFlows: [Flow] = []
    private var retiredListeners: [RetiredListener] = []
    private var retiredStatistics = SSHForwardingStatistics()
    private var scratch = [UInt8](repeating: 0, count: 32 * 1024)
    private var scheduled = false
    private var generation = 0
    private var controlDirections: Int32 = 0
    private var keepaliveDue = true
    private var nextKeepalive = DispatchTime.now()

    init(
        connectionHandler: @escaping SSHForwardingSession.ConnectionHandler,
        failureHandler: @escaping SSHForwardingSession.FailureHandler,
        logger: Logger
    ) {
        _ = Self.initialization
        self.connectionHandler = connectionHandler
        self.failureHandler = failureHandler
        self.logger = logger
    }

    deinit { cleanup() }

    func connect(_ request: SSHConnectionRequest, progress: SSHRouteProgressHandler?) async throws {
        let operationID = UUID().uuidString.lowercased()
        let hostID = request.configuration.hostID
        logger.info(
            "forwarding.connect.started",
            metadata: [
                "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "connecting",
            ])
        await disconnect()
        do {
            let opened = try await SSHSessionWorker.openAuthenticatedSession(
                using: request, timeout: 20, progress: progress, logger: logger)
            await queue.perform {
                self.retiredStatistics = SSHForwardingStatistics()
                self.routeTransport = opened.transport
                self.socket = opened.transport.socket
                self.session = opened.session
                self.bufferedTransport = SSHBufferedTransport(session: opened.session)
                libssh2_session_set_blocking(opened.session, 0)
                libssh2_keepalive_config(opened.session, 0, 20)
                self.startEvents()
            }
            try Task.checkCancellation()
            logger.info(
                "forwarding.connect.completed",
                metadata: [
                    "host_id": RemoteLogging.hostID(hostID), "operation_id": "\(operationID)",
                    "outcome": "success", "protocol": "ssh", "stage": "connected",
                ])
        } catch {
            await disconnect()
            logger.error(
                "forwarding.connect.failed",
                metadata: [
                    "error_code": RemoteLogging.errorCode(error), "host_id": RemoteLogging.hostID(hostID),
                    "operation_id": "\(operationID)", "outcome": "failure", "protocol": "ssh",
                    "stage": "connecting",
                ])
            throw error
        }
    }

    func start(_ rule: PortForwardingRule, generation: UUID) async throws {
        let operationID = UUID().uuidString.lowercased()
        logger.info(
            "forwarding.start.started",
            metadata: [
                "forwarding_kind": RemoteLogging.forwardingKind(rule.kind),
                "host_id": RemoteLogging.hostID(rule.hostID), "operation_id": "\(operationID)",
                "protocol": "ssh", "stage": "starting",
            ])
        do {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        guard session != nil else { throw TermindSSHError.disconnected }
                        if rules[rule.id] != nil {
                            continuation.resume()
                            return
                        }
                        let context = RuleContext(rule: rule, generation: generation)
                        switch rule.kind {
                        case .local, .dynamic:
                            do { context.socket = try makeListener(host: rule.bindHost, port: rule.bindPort) } catch {
                                throw TermindSSHError.route(
                                    String(
                                        localized:
                                            "Unable to listen on \(rule.bindAddress): \(error.localizedDescription)")
                                )
                            }
                            context.events = SSHSocketEvents(socket: context.socket, queue: queue) {
                                [weak self, weak context] in
                                guard let self, let context, !context.stopped else { return }
                                self.acceptLocal(context)
                            }
                            context.events?.update(read: true, write: false)
                            rules[rule.id] = context
                            report(context)
                            continuation.resume()
                        case .remote:
                            context.start = continuation
                            rules[rule.id] = context
                            pendingListeners.append(context)
                            schedulePump()
                        }
                    } catch { continuation.resume(throwing: error) }
                }
            }
            logger.info(
                "forwarding.start.completed",
                metadata: [
                    "forwarding_kind": RemoteLogging.forwardingKind(rule.kind),
                    "host_id": RemoteLogging.hostID(rule.hostID), "operation_id": "\(operationID)",
                    "outcome": "success", "protocol": "ssh", "stage": "running",
                ])
        } catch {
            logger.error(
                "forwarding.start.failed",
                metadata: [
                    "error_code": RemoteLogging.errorCode(error),
                    "forwarding_kind": RemoteLogging.forwardingKind(rule.kind),
                    "host_id": RemoteLogging.hostID(rule.hostID), "operation_id": "\(operationID)",
                    "outcome": "failure", "protocol": "ssh", "stage": "starting",
                ])
            throw error
        }
    }

    func stop(_ id: PortForwardingRule.ID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let context = rules.removeValue(forKey: id) else {
                    continuation.resume()
                    return
                }
                close(context) { continuation.resume() }
                schedulePump()
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cleanup()
                closingSockets.notify(queue: queue) { continuation.resume() }
            }
        }
    }

    func statistics() async -> SSHForwardingStatistics {
        await withCheckedContinuation { continuation in
            queue.async {
                var result = self.retiredStatistics
                for flow in self.flows.values {
                    result.plaintextSocketWriteCalls += flow.stream.socketWriteCalls
                    result.peakPlaintextQueueBytes = max(result.peakPlaintextQueueBytes, flow.stream.peakQueuedBytes)
                }
                result.passes = self.bufferedTransport?.passes ?? 0
                result.encryptedSocketWriteCalls = self.bufferedTransport?.socketWriteCalls ?? 0
                result.peakEncryptedQueueBytes = self.bufferedTransport?.peakQueuedBytes ?? 0
                continuation.resume(returning: result)
            }
        }
    }

    private func startEvents() {
        let token = generation
        transportEvents = SSHSocketEvents(socket: socket, queue: queue) { [weak self] in
            guard let self, self.generation == token else { return }
            self.wakeAll()
        }
        transportEvents?.update(read: true, write: false)
        let source = DispatchSource.makeTimerSource(queue: queue)
        // This timer services protocol deadlines and keepalive, never data throughput.
        source.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self, self.generation == token else { return }
            if DispatchTime.now() >= self.nextKeepalive { self.keepaliveDue = true }
            if self.keepaliveDue || self.opening != nil || self.listening != nil
                || !self.retiredFlows.isEmpty || !self.retiredListeners.isEmpty
            {
                self.wakeAll()
            }
        }
        timer = source
        source.resume()
        keepaliveDue = true
        schedulePump()
    }

    private func wakeAll() {
        for id in flows.keys { ready.insert(id) }
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
        guard let session, let bufferedTransport else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
        bufferedTransport.beginPass(deadline: deadline)
        do { try bufferedTransport.flush(socket: socket) } catch {
            fail(session)
            return
        }
        if bufferedTransport.isBackpressured {
            for flow in flows.values { flow.events?.update(read: false, write: false) }
            transportEvents?.update(read: false, write: true)
            return
        }
        controlDirections = 0
        var progressed = advanceListeners(session)
        if advanceOpen(session) { progressed = true }
        // Give forwarded-tcpip opens receive budget before bulk streams spend
        // the slice. The post-I/O sweep also handles opens decoded by stream I/O.
        for context in rules.values where context.remoteListener != nil {
            if acceptRemote(context) { progressed = true }
        }
        while !bufferedTransport.isBackpressured, DispatchTime.now().uptimeNanoseconds < deadline, let id = ready.pop()
        {
            guard let flow = flows[id] else { continue }
            if pump(flow, session: session, deadline: deadline) { progressed = true }
            if flow.stream.yielded && !flow.retired { ready.insert(id) }
        }
        // Any channel read/write can consume packets for another channel,
        // including forwarded-tcpip opens and control replies. Service those
        // queues after stream I/O; waiting for another socket edge would stall.
        if advanceOpen(session) { progressed = true }
        if advanceListeners(session) { progressed = true }
        for context in rules.values where context.remoteListener != nil {
            if acceptRemote(context) { progressed = true }
        }
        for flow in flows.values where flow.phase == .forwarding {
            guard let channel = flow.stream.channel else { continue }
            if (flow.stream.wantsChannelRead && libssh2_poll_channel_read(channel, 0) == 1)
                || (!flow.stream.channelEOF && libssh2_channel_eof(channel) == 1)
            {
                ready.insert(flow.id)
            }
        }
        if reap(session) { progressed = true }
        if keepaliveDue {
            var next: Int32 = 0
            let result = libssh2_keepalive_send(session, &next)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
            } else if result < 0 {
                fail(session)
                return
            } else {
                keepaliveDue = false
                nextKeepalive = .now() + .seconds(max(1, Int(next)))
            }
        }
        for context in rules.values { report(context) }
        let directions = flows.values.reduce(controlDirections) { $0 | $1.stream.blockDirections }
        var byte: UInt8 = 0
        let available = Darwin.recv(socket, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        if available == 0 || (available < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
            fail(session)
            return
        }
        // With no channel/listener libssh2 has no public session-read operation.
        // Park unsolicited bytes until the next operation can consume them;
        // never repeatedly wake on the same unread packet.
        let canRead =
            available < 0
            || flows.values.contains {
                $0.phase == .forwarding && ($0.stream.wantsChannelRead || !$0.stream.toChannel.isEmpty)
            } || rules.values.contains { $0.remoteListener != nil }
            || opening != nil || listening != nil || !retiredFlows.isEmpty || !retiredListeners.isEmpty
        do { try bufferedTransport.flush(socket: socket) } catch {
            fail(session)
            return
        }
        transportEvents?.update(
            read: canRead && !bufferedTransport.isBackpressured,
            write: bufferedTransport.wantsWrite || directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
        if progressed || bufferedTransport.exhaustedReadBudget { wakeAll() } else if !ready.isEmpty { schedulePump() }
    }

    private func blocked(_ session: OpaquePointer) {
        controlDirections |= libssh2_session_block_directions(session)
    }

    private func advanceListeners(_ session: OpaquePointer) -> Bool {
        if listening == nil {
            while !pendingListeners.isEmpty {
                let next = pendingListeners.removeFirst()
                if !next.stopped {
                    listening = next
                    break
                }
            }
        }
        guard let context = listening else { return false }
        var boundPort: Int32 = 0
        let listener = context.rule.bindHost.withCString {
            libssh2_channel_forward_listen_ex(session, $0, Int32(context.rule.bindPort), &boundPort, 128)
        }
        if let listener {
            listening = nil
            if context.stopped {
                retiredListeners.append(RetiredListener(listener, completion: context.stop ?? {}))
                context.stop = nil
            } else {
                context.remoteListener = listener
                context.start?.resume()
                context.start = nil
                report(context)
            }
            return true
        }
        let code = libssh2_session_last_errno(session)
        if code == LIBSSH2_ERROR_EAGAIN {
            blocked(session)
            return false
        }
        listening = nil
        if rules[context.rule.id] === context { rules[context.rule.id] = nil }
        let error: TermindSSHError
        switch code {
        case LIBSSH2_ERROR_SOCKET_NONE, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
            LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_BAD_SOCKET,
            LIBSSH2_ERROR_TIMEOUT:
            // A lost transport must not turn a pending listener into a rule-local failure.
            error = .disconnected
        default:
            error = SSHSessionWorker.sessionError(
                session, prefix: String(localized: "Unable to start remote forwarding"))
        }
        context.start?.resume(throwing: error)
        context.start = nil
        context.stop?()
        context.stop = nil
        return true
    }

    private func advanceOpen(_ session: OpaquePointer) -> Bool {
        if opening == nil {
            while let id = pendingOpens.pop() {
                if let flow = flows[id], flow.phase == .opening {
                    opening = flow
                    break
                }
            }
        }
        guard let flow = opening, let (host, port) = flow.target else { return false }
        let channel = host.withCString {
            libssh2_channel_direct_tcpip_ex(session, $0, Int32(port), "127.0.0.1", 0)
        }
        guard let channel else {
            if libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            opening = nil
            if !flow.retired {
                if flow.context.rule.kind == .dynamic {
                    flow.stream.toSocket.append(socksReply(0x05))
                    flow.stream.socketEOF = true
                    flow.phase = .request
                    ready.insert(flow.id)
                } else {
                    close(flow)
                }
            }
            return true
        }
        opening = nil
        flow.stream.channel = channel
        if flow.retired {
            retiredFlows.append(flow)
        } else {
            if flow.context.rule.kind == .dynamic { flow.stream.toSocket.append(socksReply(0x00)) }
            flow.phase = .forwarding
            ready.insert(flow.id)
        }
        return true
    }

    private func acceptLocal(_ context: RuleContext) {
        for _ in 0..<32 {
            let descriptor = Darwin.accept(context.socket, nil, nil)
            guard descriptor >= 0 else { break }
            makeNonblocking(descriptor)
            var yes: Int32 = 1
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
            let flow = Flow(socket: descriptor, context: context)
            register(flow)
            watch(flow)
            if flow.phase == .opening { pendingOpens.insert(flow.id) }
        }
        schedulePump()
    }

    private func acceptRemote(_ context: RuleContext) -> Bool {
        guard let listener = context.remoteListener, let host = context.rule.targetHost,
            let port = context.rule.targetPort
        else { return false }
        var progressed = false
        for _ in 0..<32 {
            guard let channel = libssh2_channel_forward_accept(listener) else {
                if let session, libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN { blocked(session) }
                break
            }
            progressed = true
            let flow = Flow(socket: -1, context: context, channel: channel)
            register(flow)
            let connector = SSHForwardingConnector(queue: queue) { [weak self, weak flow] result in
                guard let self, let flow, !flow.retired else {
                    if case .success(let socket) = result { Darwin.close(socket) }
                    return
                }
                flow.connector = nil
                switch result {
                case .success(let socket):
                    flow.stream.socket = socket
                    flow.phase = .forwarding
                    self.watch(flow)
                    self.ready.insert(flow.id)
                case .failure: self.close(flow)
                }
                self.schedulePump()
            }
            flow.connector = connector
            connector.start(host: host, port: port)
        }
        return progressed
    }

    private func register(_ flow: Flow) {
        flows[flow.id] = flow
        flow.context.flows[flow.id] = flow
        ready.insert(flow.id)
    }

    private func watch(_ flow: Flow) {
        flow.events = SSHSocketEvents(socket: flow.stream.socket, queue: queue) { [weak self, weak flow] in
            guard let self, let flow, !flow.retired else { return }
            self.ready.insert(flow.id)
            self.schedulePump()
        }
        updateInterest(flow)
    }

    private func updateInterest(_ flow: Flow) {
        let reading: Bool
        switch flow.phase {
        case .forwarding: reading = flow.stream.wantsSocketRead
        case .greeting, .request: reading = !flow.stream.socketEOF
        case .opening, .connecting: reading = false
        }
        flow.events?.update(read: reading, write: flow.stream.socketWriteBlocked)
    }

    private func pump(_ flow: Flow, session: OpaquePointer, deadline: UInt64) -> Bool {
        guard !flow.retired else { return false }
        flow.stream.beginTurn()
        var progressed = false
        do {
            switch flow.phase {
            case .forwarding:
                progressed = try flow.stream.pump(session: session, scratch: &scratch, deadline: deadline)
                if flow.stream.finished {
                    close(flow)
                    return true
                }
            case .greeting, .request:
                if !flow.stream.socketEOF {
                    let count = Darwin.recv(flow.stream.socket, &scratch, scratch.count, 0)
                    if count > 0 {
                        flow.handshake.append(contentsOf: scratch.prefix(count))
                        guard flow.handshake.count <= 64 * 1024 else {
                            close(flow)
                            return true
                        }
                        handleSOCKSHandshake(flow, session: session)
                        progressed = true
                    } else if count == 0 {
                        flow.stream.socketEOF = true
                        progressed = true
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        close(flow)
                        return true
                    }
                }
                if try flow.stream.flushSocket(deadline: deadline) { progressed = true }
                if flow.stream.socketEOF && flow.stream.toSocket.isEmpty {
                    close(flow)
                    return true
                }
            case .opening:
                if try flow.stream.flushSocket(deadline: deadline) { progressed = true }
            case .connecting: break
            }
        } catch {
            close(flow)
            return true
        }
        updateInterest(flow)
        return progressed
    }

    private func report(_ context: RuleContext) {
        guard !context.stopped, context.start == nil, context.reportedCount != context.flows.count else { return }
        context.reportedCount = context.flows.count
        connectionHandler(context.rule.id, context.generation, context.reportedCount)
    }

    private func close(_ flow: Flow) {
        guard !flow.retired else { return }
        flow.retired = true
        retiredStatistics.plaintextSocketWriteCalls += flow.stream.socketWriteCalls
        retiredStatistics.peakPlaintextQueueBytes = max(
            retiredStatistics.peakPlaintextQueueBytes, flow.stream.peakQueuedBytes)
        flows[flow.id] = nil
        flow.context.flows[flow.id] = nil
        flow.connector?.cancel()
        flow.connector = nil
        let descriptor = flow.stream.socket
        flow.stream.socket = -1
        if let events = flow.events {
            closingSockets.enter()
            events.cancel { [closingSockets] in
                Darwin.close(descriptor)
                closingSockets.leave()
            }
            flow.events = nil
        } else if descriptor >= 0 {
            Darwin.close(descriptor)
        }
        if flow.stream.channel != nil { retiredFlows.append(flow) }
    }

    private func close(_ context: RuleContext, completion: @escaping @Sendable () -> Void) {
        context.stopped = true
        context.start?.resume(throwing: CancellationError())
        context.start = nil
        for flow in Array(context.flows.values) { close(flow) }
        if context === listening {
            // Drain the in-flight global request and cancel the resulting
            // listener before allowing a replacement to bind the same port.
            context.stop = completion
            return
        }
        if let listener = context.remoteListener {
            retiredListeners.append(RetiredListener(listener, completion: completion))
            context.remoteListener = nil
        } else if let events = context.events {
            let descriptor = context.socket
            context.socket = -1
            context.events = nil
            closingSockets.enter()
            events.cancel { [closingSockets] in
                Darwin.close(descriptor)
                completion()
                closingSockets.leave()
            }
        } else {
            completion()
        }
    }

    private func reap(_ session: OpaquePointer) -> Bool {
        var progressed = false
        retiredFlows.removeAll { flow in
            guard flow.stream.finishPendingWrite(session: session), let channel = flow.stream.channel else {
                blocked(session)
                return false
            }
            flow.stream.toChannel.removeAll()
            flow.stream.toSocket.removeAll()
            let result = libssh2_channel_free(channel)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            flow.stream.channel = nil
            progressed = true
            return true
        }
        retiredListeners.removeAll { entry in
            let result = libssh2_channel_forward_cancel(entry.listener)
            if result == LIBSSH2_ERROR_EAGAIN {
                blocked(session)
                return false
            }
            entry.completion()
            progressed = true
            return true
        }
        return progressed
    }

    private func fail(_ session: OpaquePointer) {
        let message = SSHSessionWorker.sessionError(
            session, prefix: String(localized: "The forwarding SSH connection closed")
        ).localizedDescription
        cleanup()
        failureHandler(message)
    }

    private func cleanup() {
        generation += 1
        scheduled = false
        timer?.cancel()
        timer = nil
        for context in rules.values { close(context, completion: {}) }
        rules.removeAll()
        // Shutdown makes disposal nonblocking even if a peer stopped reading.
        if socket >= 0 { _ = Darwin.shutdown(socket, SHUT_RDWR) }
        if let session { bufferedTransport?.dispose(session: session) }
        bufferedTransport = nil
        session = nil
        for entry in retiredListeners { entry.completion() }
        retiredListeners.removeAll()
        retiredFlows.removeAll()
        opening = nil
        listening?.stop?()
        listening?.stop = nil
        listening = nil
        pendingListeners.removeAll()
        flows.removeAll()
        ready = SSHReadyQueue()
        pendingOpens = SSHReadyQueue()
        if let transport = routeTransport {
            if let events = transportEvents {
                closingSockets.enter()
                events.cancel { [closingSockets] in
                    transport.close()
                    closingSockets.leave()
                }
            } else {
                transport.close()
            }
        }
        transportEvents = nil
        routeTransport = nil
        socket = -1
    }
    private func handleSOCKSHandshake(_ flow: Flow, session: OpaquePointer) {
        switch flow.phase {
        case .greeting:
            guard flow.handshake.count >= 2 else { return }
            let methods = Int(flow.handshake[1])
            guard flow.handshake.count >= 2 + methods else { return }
            guard flow.handshake[0] == 0x05,
                flow.handshake[2..<(2 + methods)].contains(0x00)
            else {
                flow.stream.toSocket.append(contentsOf: [0x05, 0xff])
                flow.stream.socketEOF = true
                return
            }
            flow.handshake = Data(flow.handshake.dropFirst(2 + methods))
            flow.stream.toSocket.append(contentsOf: [0x05, 0x00])
            flow.phase = .request
            handleSOCKSHandshake(flow, session: session)
        case .request:
            guard flow.handshake.count >= 4 else { return }
            guard flow.handshake[0] == 0x05, flow.handshake[1] == 0x01 else {
                flow.stream.toSocket.append(socksReply(0x07))
                flow.stream.socketEOF = true
                return
            }
            let parsed: (String, Int, Int)?
            switch flow.handshake[3] {
            case 0x01:
                guard flow.handshake.count >= 10 else { return }
                parsed = (
                    flow.handshake[4..<8].map(String.init).joined(separator: "."),
                    Int(flow.handshake[8]) << 8 | Int(flow.handshake[9]), 10
                )
            case 0x03:
                guard flow.handshake.count >= 5 else { return }
                let length = Int(flow.handshake[4])
                guard flow.handshake.count >= 7 + length else { return }
                parsed = (
                    String(decoding: flow.handshake[5..<(5 + length)], as: UTF8.self),
                    Int(flow.handshake[5 + length]) << 8 | Int(flow.handshake[6 + length]),
                    7 + length
                )
            case 0x04:
                guard flow.handshake.count >= 22 else { return }
                var address = in6_addr()
                _ = withUnsafeMutableBytes(of: &address) { destination in
                    flow.handshake[4..<20].copyBytes(to: destination)
                }
                var chars = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                _ = inet_ntop(AF_INET6, &address, &chars, socklen_t(chars.count))
                let end = chars.firstIndex(of: 0) ?? chars.endIndex
                parsed = (
                    String(decoding: chars[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self),
                    Int(flow.handshake[20]) << 8 | Int(flow.handshake[21]), 22
                )
            default:
                flow.stream.toSocket.append(socksReply(0x08))
                flow.stream.socketEOF = true
                return
            }
            guard let (host, port, consumed) = parsed else { return }
            flow.target = (host, port)
            flow.stream.toChannel.append(Data(flow.handshake.dropFirst(consumed)))
            flow.handshake.removeAll()
            flow.phase = .opening
            pendingOpens.insert(flow.id)
            schedulePump()
        case .opening, .connecting, .forwarding: break
        }
    }

    private func socksReply(_ code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    private func makeListener(host: String, port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_PASSIVE
        var result: UnsafeMutablePointer<addrinfo>?
        let resolved = getaddrinfo(host, String(port), &hints, &result)
        guard resolved == 0, let first = result else {
            throw TermindSSHError.socket(String(cString: gai_strerror(resolved)))
        }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            let candidate = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if candidate >= 0 {
                var yes: Int32 = 1
                setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                // Closed streams can remain in TIME_WAIT after the listener is released.
                // REUSEADDR permits rebinding then without sharing an active listener.
                if setsockopt(candidate, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0,
                    Darwin.bind(candidate, info.ai_addr, info.ai_addrlen) == 0,
                    Darwin.listen(candidate, 128) == 0
                {
                    makeNonblocking(candidate)
                    return candidate
                }
                Darwin.close(candidate)
            }
            cursor = info.ai_next
        }
        throw TermindSSHError.socket(String(cString: strerror(errno)))
    }

    private func makeNonblocking(_ socket: Int32) {
        let flags = fcntl(socket, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(socket, F_SETFL, flags | O_NONBLOCK) }
    }

}

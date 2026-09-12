import CSSH2
import Darwin
import Foundation
import TermindApplication
import TermindDomain

public actor SSHForwardingSession {
    public typealias ConnectionHandler = @Sendable (PortForwardingRule.ID, Int) -> Void
    public typealias FailureHandler = @Sendable (String) -> Void

    private let worker: SSHForwardingWorker

    public init(
        connectionHandler: @escaping ConnectionHandler,
        failureHandler: @escaping FailureHandler
    ) {
        worker = SSHForwardingWorker(
            connectionHandler: connectionHandler, failureHandler: failureHandler
        )
    }

    public func connect(_ configuration: SSHConnectionConfiguration) async throws {
        try await worker.connect(configuration)
    }

    public func start(_ rule: PortForwardingRule) async throws {
        try await worker.start(rule)
    }

    public func stop(_ id: PortForwardingRule.ID) async {
        await worker.stop(id)
    }

    public func disconnect() async {
        await worker.disconnect()
    }
}

private nonisolated final class SSHForwardingWorker: @unchecked Sendable {
    private static let initialization: Void = {
        precondition(libssh2_init(0) == 0, "libssh2 initialization failed")
    }()

    private final class RuleContext {
        let rule: PortForwardingRule
        var socket: Int32 = -1
        var remoteListener: OpaquePointer?
        var flows: [UUID: Flow] = [:]

        init(rule: PortForwardingRule) { self.rule = rule }
    }

    private final class Flow {
        enum Phase { case greeting, request, forwarding }
        let id = UUID()
        var socket: Int32
        var channel: OpaquePointer?
        var phase: Phase
        var handshake = Data()
        var toChannel = Data()
        var toSocket = Data()
        var socketEOF = false
        var channelEOF = false
        var socketWriteClosed = false
        var channelWriteClosed = false

        init(socket: Int32, dynamic: Bool, channel: OpaquePointer? = nil) {
            self.socket = socket
            self.phase = dynamic ? .greeting : .forwarding
            self.channel = channel
        }
    }

    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.forwarding")
    private let connectionHandler: SSHForwardingSession.ConnectionHandler
    private let failureHandler: SSHForwardingSession.FailureHandler
    private var socket: Int32 = -1
    private var routeTransport: SSHRoutedSocket?
    private var session: OpaquePointer?
    private var rules: [PortForwardingRule.ID: RuleContext] = [:]
    private var timer: (any DispatchSourceTimer)?

    public init(
        connectionHandler: @escaping SSHForwardingSession.ConnectionHandler,
        failureHandler: @escaping SSHForwardingSession.FailureHandler
    ) {
        _ = Self.initialization
        self.connectionHandler = connectionHandler
        self.failureHandler = failureHandler
    }

    public func connect(_ configuration: SSHConnectionConfiguration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    cleanup()
                    routeTransport = try SSHRoutedSocket.open(
                        host: configuration.host, port: configuration.port,
                        proxy: configuration.proxy, jumps: configuration.jumps, timeout: 20
                    )
                    guard let routeTransport else { throw TermindSSHError.disconnected }
                    socket = routeTransport.socket
                    guard let created = libssh2_session_init_ex(nil, nil, nil, nil) else {
                        throw TermindSSHError.library(String(localized: "Unable to create an SSH forwarding session."))
                    }
                    session = created
                    libssh2_session_set_blocking(created, 1)
                    try SSHSessionWorker.performHandshake(
                        created, socket: socket,
                        peer: SSHSocketConnector.peerDescription(
                            socket: socket,
                            fallbackHost: configuration.host,
                            port: configuration.port
                        )
                    )
                    let observed = try SSHSessionWorker.observation(
                        host: configuration.host, port: configuration.port, session: created
                    )
                    try SSHSessionWorker.validateHostKey(
                        observed, expected: configuration.expectedHostKeys
                    )
                    try SSHSessionWorker.authenticate(
                        username: configuration.username,
                        credentials: configuration.credentials, session: created
                    )
                    libssh2_session_set_blocking(created, 0)
                    libssh2_keepalive_config(created, 1, 20)
                    startTimer()
                    continuation.resume()
                } catch {
                    cleanup()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func start(_ rule: PortForwardingRule) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    guard let session else { throw TermindSSHError.disconnected }
                    if rules[rule.id] != nil {
                        continuation.resume()
                        return
                    }
                    let context = RuleContext(rule: rule)
                    switch rule.kind {
                    case .local, .dynamic:
                        do {
                            context.socket = try makeListener(
                                host: rule.bindHost, port: rule.bindPort
                            )
                        } catch {
                            throw TermindSSHError.route(
                                String(
                                    localized: "Unable to listen on \(rule.bindAddress): \(error.localizedDescription)")
                            )
                        }
                    case .remote:
                        var boundPort: Int32 = 0
                        let listener = rule.bindHost.withCString { host in
                            libssh2_channel_forward_listen_ex(
                                session, host, Int32(rule.bindPort), &boundPort, 64
                            )
                        }
                        guard let listener else {
                            throw TermindSSHError.route(
                                SSHSessionWorker.sessionError(
                                    session, prefix: String(localized: "Unable to start remote forwarding")
                                ).localizedDescription
                            )
                        }
                        context.remoteListener = listener
                    }
                    rules[rule.id] = context
                    connectionHandler(rule.id, 0)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func stop(_ id: PortForwardingRule.ID) async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let context = rules.removeValue(forKey: id) { close(context) }
                continuation.resume()
            }
        }
    }

    public func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                cleanup()
                continuation.resume()
            }
        }
    }

    private func startTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(12), leeway: .milliseconds(4))
        source.setEventHandler { [weak self] in self?.pump() }
        timer = source
        source.resume()
    }

    private func pump() {
        guard let session else { return }
        for context in Array(rules.values) {
            switch context.rule.kind {
            case .local, .dynamic: acceptLocal(context, session: session)
            case .remote: acceptRemote(context)
            }
            for flow in Array(context.flows.values) { pump(flow, in: context, session: session) }
            connectionHandler(context.rule.id, context.flows.count)
        }
        var next = Int32(0)
        let keepalive = libssh2_keepalive_send(session, &next)
        if keepalive < 0, keepalive != LIBSSH2_ERROR_EAGAIN {
            let message = SSHSessionWorker.sessionError(
                session, prefix: String(localized: "The forwarding SSH connection closed")
            ).localizedDescription
            cleanup()
            failureHandler(message)
        }
    }

    private func acceptLocal(_ context: RuleContext, session: OpaquePointer) {
        while true {
            let accepted = Darwin.accept(context.socket, nil, nil)
            guard accepted >= 0 else { break }
            makeNonblocking(accepted)
            let flow = Flow(socket: accepted, dynamic: context.rule.kind == .dynamic)
            if context.rule.kind == .local {
                guard let targetHost = context.rule.targetHost, let targetPort = context.rule.targetPort else {
                    Darwin.close(accepted)
                    continue
                }
                flow.channel = targetHost.withCString { target in
                    libssh2_channel_direct_tcpip_ex(session, target, Int32(targetPort), "127.0.0.1", 0)
                }
                guard flow.channel != nil else {
                    Darwin.close(accepted)
                    continue
                }
            }
            context.flows[flow.id] = flow
        }
    }

    private func acceptRemote(_ context: RuleContext) {
        guard let listener = context.remoteListener,
            let targetHost = context.rule.targetHost, let targetPort = context.rule.targetPort
        else { return }
        while let channel = libssh2_channel_forward_accept(listener) {
            do {
                let local = try SSHSocketConnector.open(
                    host: targetHost, port: targetPort, timeout: 5
                )
                makeNonblocking(local)
                let flow = Flow(socket: local, dynamic: false, channel: channel)
                context.flows[flow.id] = flow
            } catch {
                _ = libssh2_channel_free(channel)
            }
        }
    }

    private func pump(_ flow: Flow, in context: RuleContext, session: OpaquePointer) {
        let highWaterMark = 2 * 1024 * 1024
        if !flow.socketEOF,
            (flow.phase == .forwarding ? flow.toChannel.count : flow.handshake.count) < highWaterMark
        {
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let count = Darwin.recv(flow.socket, &buffer, buffer.count, 0)
            if count > 0 {
                let data = Data(buffer.prefix(count))
                if flow.phase == .forwarding {
                    flow.toChannel.append(data)
                } else {
                    flow.handshake.append(data)
                    if flow.handshake.count > 64 * 1024 {
                        close(flow, in: context)
                        return
                    }
                    handleSOCKSHandshake(flow, session: session)
                }
            } else if count == 0 {
                flow.socketEOF = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                close(flow, in: context)
                return
            }
        }

        if let channel = flow.channel {
            while !flow.toChannel.isEmpty {
                let written = flow.toChannel.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                    return libssh2_channel_write_ex(channel, 0, base, bytes.count)
                }
                if written > 0 {
                    flow.toChannel.removeFirst(written)
                } else if written == LIBSSH2_ERROR_EAGAIN {
                    break
                } else {
                    close(flow, in: context)
                    return
                }
            }
            if flow.socketEOF, flow.toChannel.isEmpty, !flow.channelWriteClosed {
                let result = libssh2_channel_send_eof(channel)
                if result == 0 {
                    flow.channelWriteClosed = true
                } else if result != LIBSSH2_ERROR_EAGAIN {
                    close(flow, in: context)
                    return
                }
            }
            if flow.toSocket.count < highWaterMark {
                var buffer = [CChar](repeating: 0, count: 32 * 1024)
                while flow.toSocket.count < highWaterMark {
                    let count = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
                    if count > 0 {
                        flow.toSocket.append(Data(bytes: buffer, count: count))
                    } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                        break
                    } else {
                        close(flow, in: context)
                        return
                    }
                }
            }
            if libssh2_channel_eof(channel) == 1 { flow.channelEOF = true }
        }

        while !flow.toSocket.isEmpty {
            let sent = flow.toSocket.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.send(flow.socket, base, bytes.count, 0)
            }
            if sent > 0 {
                flow.toSocket.removeFirst(sent)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                close(flow, in: context)
                return
            }
        }
        if flow.channelEOF, flow.toSocket.isEmpty, !flow.socketWriteClosed {
            _ = Darwin.shutdown(flow.socket, SHUT_WR)
            flow.socketWriteClosed = true
        }
        if flow.socketEOF,
            flow.channel == nil || flow.channelEOF,
            flow.toChannel.isEmpty, flow.toSocket.isEmpty
        {
            close(flow, in: context)
        }
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
                flow.toSocket.append(contentsOf: [0x05, 0xff])
                flow.socketEOF = true
                return
            }
            flow.handshake.removeFirst(2 + methods)
            flow.toSocket.append(contentsOf: [0x05, 0x00])
            flow.phase = .request
            handleSOCKSHandshake(flow, session: session)
        case .request:
            guard flow.handshake.count >= 4 else { return }
            guard flow.handshake[0] == 0x05, flow.handshake[1] == 0x01 else {
                flow.toSocket.append(socksReply(0x07))
                flow.socketEOF = true
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
                flow.toSocket.append(socksReply(0x08))
                flow.socketEOF = true
                return
            }
            guard let (host, port, consumed) = parsed else { return }
            flow.handshake.removeFirst(consumed)
            flow.channel = host.withCString { target in
                libssh2_channel_direct_tcpip_ex(session, target, Int32(port), "127.0.0.1", 0)
            }
            guard flow.channel != nil else {
                flow.toSocket.append(socksReply(0x05))
                flow.socketEOF = true
                return
            }
            flow.toSocket.append(socksReply(0x00))
            flow.phase = .forwarding
            if !flow.handshake.isEmpty {
                flow.toChannel.append(flow.handshake)
                flow.handshake.removeAll()
            }
        case .forwarding: break
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
                if Darwin.bind(candidate, info.ai_addr, info.ai_addrlen) == 0,
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

    private func close(_ flow: Flow, in context: RuleContext) {
        context.flows[flow.id] = nil
        if flow.socket >= 0 {
            Darwin.close(flow.socket)
            flow.socket = -1
        }
        if let channel = flow.channel {
            _ = libssh2_channel_close(channel)
            _ = libssh2_channel_free(channel)
            flow.channel = nil
        }
    }

    private func close(_ context: RuleContext) {
        for flow in Array(context.flows.values) { close(flow, in: context) }
        if context.socket >= 0 {
            Darwin.close(context.socket)
            context.socket = -1
        }
        if let listener = context.remoteListener {
            _ = libssh2_channel_forward_cancel(listener)
            context.remoteListener = nil
        }
    }

    private func cleanup() {
        timer?.cancel()
        timer = nil
        for context in Array(rules.values) { close(context) }
        rules.removeAll()
        if let session {
            _ = libssh2_session_disconnect_ex(
                session, SSH_DISCONNECT_BY_APPLICATION, "Termind stopped forwarding", ""
            )
            _ = libssh2_session_free(session)
            self.session = nil
        }
        socket = -1
        routeTransport?.close()
        routeTransport = nil
    }
}

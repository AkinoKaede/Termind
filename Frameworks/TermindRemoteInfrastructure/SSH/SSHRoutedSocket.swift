import CSSH2
import Darwin
import Foundation
import TermindApplication
import TermindDomain

import struct TermindDomain.Host

/// One authenticated SSH hop used before the destination session.

/// A socket carrying bytes to the final SSH server, either directly or through
/// a chain of authenticated direct-tcpip channels. The caller owns the final
/// libssh2 session; this object owns every preceding hop and its bridge pump.
public nonisolated final class SSHRoutedSocket: @unchecked Sendable {
    public let socket: Int32
    private var bridges: [SSHChannelSocketBridge]
    private var isClosed = false

    fileprivate init(socket: Int32, bridges: [SSHChannelSocketBridge]) {
        self.socket = socket
        self.bridges = bridges
    }

    deinit { close() }

    public static func open(
        host: String, port: Int, proxy: SSHTransportProxy?,
        jumps: [SSHRouteHopConfiguration], timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil
    ) throws -> SSHRoutedSocket {
        guard !jumps.isEmpty else {
            return SSHRoutedSocket(
                socket: try SSHSocketConnector.open(
                    host: host, port: port, proxy: proxy, timeout: timeout
                ),
                bridges: []
            )
        }

        var bridges: [SSHChannelSocketBridge] = []
        var currentSocket = try SSHSocketConnector.open(
            host: jumps[0].host, port: jumps[0].port,
            proxy: jumps[0].proxy, timeout: timeout
        )
        do {
            for index in jumps.indices {
                let hop = jumps[index]
                progress?(.connecting(hop.id))
                let session = try connectHop(
                    hop, socket: currentSocket, level: index + 1,
                    timeout: timeout, progress: progress
                )
                progress?(.connected(hop.id))
                let nextHost: String
                let nextPort: Int
                let nextProxy: SSHTransportProxy?
                if jumps.indices.contains(index + 1) {
                    let next = jumps[index + 1]
                    nextHost = next.host
                    nextPort = next.port
                    nextProxy = next.proxy
                } else {
                    nextHost = host
                    nextPort = port
                    nextProxy = proxy
                }

                let channelHost = nextProxy?.hostname ?? nextHost
                let channelPort = nextProxy?.port ?? nextPort
                guard
                    let channel = channelHost.withCString({ target in
                        libssh2_channel_direct_tcpip_ex(
                            session, target, Int32(channelPort), "127.0.0.1", 0
                        )
                    })
                else {
                    _ = libssh2_session_disconnect_ex(
                        session, SSH_DISCONNECT_BY_APPLICATION, "Termind route failed", ""
                    )
                    _ = libssh2_session_free(session)
                    Darwin.close(currentSocket)
                    throw TermindSSHError.route(
                        "Jump Host \(index + 1) (\(hop.name)) denied TCP forwarding."
                    )
                }

                let bridge = try SSHChannelSocketBridge(
                    transportSocket: currentSocket, session: session, channel: channel,
                    timeout: timeout
                )
                bridges.append(bridge)
                currentSocket = bridge.clientSocket
                if let nextProxy {
                    do {
                        try SSHSocketConnector.negotiate(
                            socket: currentSocket, host: nextHost, port: nextPort,
                            proxy: nextProxy
                        )
                    } catch {
                        throw TermindSSHError.route(
                            "Proxy after Jump Host \(index + 1) (\(hop.name)): \(error.localizedDescription)"
                        )
                    }
                }
            }
            return SSHRoutedSocket(socket: currentSocket, bridges: bridges)
        } catch {
            Darwin.close(currentSocket)
            for bridge in bridges.reversed() { bridge.close() }
            throw error
        }
    }

    public static func open(
        host: String, port: Int, proxy: SSHTransportProxy?,
        jumps: [SSHRouteHopConfiguration], timeout: TimeInterval,
        progress: SSHRouteProgressHandler? = nil,
        authorizeHostKey: SSHHostKeyAuthorizer?,
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil,
        hostKeyConstraints: [Host.ID: SSHHostKeyConstraint] = [:]
    ) async throws -> SSHRoutedSocket {
        let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.route-opening")
        let state = SSHRouteOpeningState()
        let exchange = SSHKeyboardInteractiveExchange(
            configuration: SSHConnectionConfiguration(
                hostID: UUID(), host: host, port: port, username: "", credentials: [], expectedHostKeys: []
            ), handler: keyboardInteractive
        )
        return try await withTaskCancellationHandler {
            do {
                let firstProxy = jumps.first?.proxy ?? proxy
                if let id = firstProxy?.ownerHostID { progress?(.proxyConnecting(id)) }
                try await queue.perform {
                    try state.openFirst(
                        destinationHost: host, destinationPort: port,
                        destinationProxy: proxy, jumps: jumps, timeout: timeout
                    )
                }
                if let id = firstProxy?.ownerHostID { progress?(.proxyConnected(id)) }
                for index in jumps.indices {
                    try Task.checkCancellation()
                    let hop = jumps[index]
                    progress?(.connecting(hop.id))
                    let observed: SSHHostKeyObservation
                    do {
                        observed = try await queue.perform {
                            try state.beginHop(
                                hop, level: index + 1, timeout: timeout
                            )
                        }
                        let requiredApproval = !hop.expectedHostKeys.contains(observed.identity)
                        try await SSHConnectionOpener.authorizeHostKey(
                            hostID: hop.id, observed: observed,
                            expected: hop.expectedHostKeys,
                            constraint: hostKeyConstraints[hop.id],
                            authorizer: authorizeHostKey
                        )
                        try Task.checkCancellation()
                        try await queue.perform {
                            try state.completeHop(
                                hop, level: index + 1,
                                destinationHost: host, destinationPort: port,
                                destinationProxy: proxy, jumps: jumps,
                                index: index, timeout: timeout,
                                afterHostKeyApproval: requiredApproval,
                                progress: progress, keyboardInteractive: exchange
                            )
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as SSHInteractionRequired {
                        throw error
                    } catch {
                        throw routeFailure(error, hop: hop, level: index + 1)
                    }
                    progress?(.connected(hop.id))
                }
                return try await queue.perform { try state.takeResult() }
            } catch {
                await queue.perform { state.cleanup() }
                throw error
            }
        } onCancel: {
            exchange.cancel()
            state.cancel()
            queue.async { state.cleanup() }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(socket)
        for bridge in bridges.reversed() { bridge.close() }
        bridges.removeAll()
    }

    private static func connectHop(
        _ hop: SSHRouteHopConfiguration, socket: Int32, level: Int,
        timeout: TimeInterval,
        progress: SSHRouteProgressHandler?
    ) throws -> OpaquePointer {
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw TermindSSHError.route("Jump Host \(level) (\(hop.name)): unable to create SSH session.")
        }
        do {
            libssh2_session_set_blocking(session, 1)
            try SSHConnectionOpener.performHandshake(
                session, socket: socket,
                peer: SSHSocketConnector.peerDescription(
                    socket: socket, fallbackHost: hop.host, port: hop.port
                ),
                timeout: timeout
            )
            let observed = try SSHConnectionOpener.observation(
                host: hop.host, port: hop.port, libssh2Session: session
            )
            try SSHConnectionOpener.validateHostKey(observed, expected: hop.expectedHostKeys)
            progress?(.authenticating(hop.id))
            _ = try SSHConnectionOpener.authenticate(
                username: hop.username, credentials: hop.credentials, libssh2Session: session
            )
            progress?(.authenticated(hop.id))
            return session
        } catch {
            _ = libssh2_session_disconnect_ex(
                session, SSH_DISCONNECT_BY_APPLICATION, "Termind route failed", ""
            )
            _ = libssh2_session_free(session)
            throw TermindSSHError.routeHost(
                hostID: hop.id,
                authentication: (error as? TermindSSHError)?.shouldRequestAuthentication == true,
                serverChallenge: (error as? TermindSSHError)?.isServerAuthenticationChallenge == true,
                hostKey: (error as? TermindSSHError)?.isHostKeyChanged == true,
                message: "Jump Host \(level) (\(hop.name)): \(error.localizedDescription)"
            )
        }
    }

    private static func routeFailure(
        _ error: any Error, hop: SSHRouteHopConfiguration, level: Int
    ) -> TermindSSHError {
        let ssh = error as? TermindSSHError
        let hostKeyFailure: Bool
        switch ssh {
        case .untrustedHost, .hostKeyChanged, .mismatchedHostKey:
            hostKeyFailure = true
        default:
            hostKeyFailure = false
        }
        return TermindSSHError.routeHost(
            hostID: hop.id,
            authentication: ssh?.shouldRequestAuthentication == true,
            serverChallenge: ssh?.isServerAuthenticationChallenge == true,
            hostKey: hostKeyFailure,
            message: "Jump Host \(level) (\(hop.name)): \(error.localizedDescription)"
        )
    }
}

private nonisolated final class SSHRouteOpeningState: @unchecked Sendable {
    private let cancellationLock = NSLock()
    private var currentSocket: Int32 = -1
    private var cancellableSocket: Int32 = -1
    private var bridges: [SSHChannelSocketBridge] = []
    private var pendingSession: OpaquePointer?

    func openFirst(
        destinationHost: String, destinationPort: Int,
        destinationProxy: SSHTransportProxy?, jumps: [SSHRouteHopConfiguration],
        timeout: TimeInterval
    ) throws {
        if let first = jumps.first {
            currentSocket = try SSHSocketConnector.open(
                host: first.host, port: first.port,
                proxy: first.proxy, timeout: timeout
            )
        } else {
            currentSocket = try SSHSocketConnector.open(
                host: destinationHost, port: destinationPort,
                proxy: destinationProxy, timeout: timeout
            )
        }
        setCancellableSocket(currentSocket)
    }

    func beginHop(
        _ hop: SSHRouteHopConfiguration, level: Int,
        timeout: TimeInterval
    ) throws -> SSHHostKeyObservation {
        guard pendingSession == nil else { throw TermindSSHError.disconnected }
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            throw TermindSSHError.route(
                "Jump Host \(level) (\(hop.name)): unable to create SSH session."
            )
        }
        pendingSession = session
        libssh2_session_set_blocking(session, 1)
        try SSHConnectionOpener.performHandshake(
            session, socket: currentSocket,
            peer: SSHSocketConnector.peerDescription(
                socket: currentSocket, fallbackHost: hop.host, port: hop.port
            ),
            timeout: timeout
        )
        return try SSHConnectionOpener.observation(
            host: hop.host, port: hop.port, libssh2Session: session
        )
    }

    func completeHop(
        _ hop: SSHRouteHopConfiguration, level: Int,
        destinationHost: String, destinationPort: Int,
        destinationProxy: SSHTransportProxy?, jumps: [SSHRouteHopConfiguration],
        index: Int, timeout: TimeInterval,
        afterHostKeyApproval: Bool,
        progress: SSHRouteProgressHandler?, keyboardInteractive: SSHKeyboardInteractiveExchange
    ) throws {
        keyboardInteractive.setHop(hop)
        guard let session = pendingSession else { throw TermindSSHError.disconnected }
        progress?(.authenticating(hop.id))
        _ = try SSHConnectionOpener.authenticate(
            username: hop.username, credentials: hop.credentials,
            libssh2Session: session,
            afterHostKeyApproval: afterHostKeyApproval,
            keyboardInteractive: keyboardInteractive, socket: currentSocket
        )
        progress?(.authenticated(hop.id))

        let nextHost: String
        let nextPort: Int
        let nextProxy: SSHTransportProxy?
        if jumps.indices.contains(index + 1) {
            let next = jumps[index + 1]
            nextHost = next.host
            nextPort = next.port
            nextProxy = next.proxy
        } else {
            nextHost = destinationHost
            nextPort = destinationPort
            nextProxy = destinationProxy
        }
        let channelHost = nextProxy?.hostname ?? nextHost
        let channelPort = nextProxy?.port ?? nextPort
        guard
            let channel = channelHost.withCString({ target in
                libssh2_channel_direct_tcpip_ex(
                    session, target, Int32(channelPort), "127.0.0.1", 0
                )
            })
        else {
            throw TermindSSHError.route(
                "Jump Host \(level) (\(hop.name)) denied TCP forwarding."
            )
        }
        let transportSocket = currentSocket
        pendingSession = nil
        currentSocket = -1
        setCancellableSocket(-1)
        let bridge = try SSHChannelSocketBridge(
            transportSocket: transportSocket, session: session,
            channel: channel, timeout: timeout
        )
        bridges.append(bridge)
        currentSocket = bridge.clientSocket
        setCancellableSocket(currentSocket)
        if let nextProxy {
            do {
                if let id = nextProxy.ownerHostID { progress?(.proxyConnecting(id)) }
                try SSHSocketConnector.negotiate(
                    socket: currentSocket, host: nextHost,
                    port: nextPort, proxy: nextProxy
                )
                if let id = nextProxy.ownerHostID { progress?(.proxyConnected(id)) }
            } catch {
                if error is TermindSSHError,
                    (error as? TermindSSHError)?.isProxyAuthentication == true
                {
                    throw error
                }
                throw TermindSSHError.route(
                    "Proxy after Jump Host \(level) (\(hop.name)): \(error.localizedDescription)"
                )
            }
        }
    }

    func takeResult() throws -> SSHRoutedSocket {
        guard currentSocket >= 0, pendingSession == nil else {
            throw TermindSSHError.disconnected
        }
        let result = SSHRoutedSocket(socket: currentSocket, bridges: bridges)
        currentSocket = -1
        setCancellableSocket(-1)
        bridges = []
        return result
    }

    func cleanup() {
        if let pendingSession {
            _ = libssh2_session_disconnect_ex(
                pendingSession, SSH_DISCONNECT_BY_APPLICATION,
                "Termind route cancelled", ""
            )
            _ = libssh2_session_free(pendingSession)
            self.pendingSession = nil
        }
        if currentSocket >= 0 {
            Darwin.close(currentSocket)
            currentSocket = -1
        }
        setCancellableSocket(-1)
        for bridge in bridges.reversed() { bridge.close() }
        bridges.removeAll()
    }

    func cancel() {
        cancellationLock.withLock {
            if cancellableSocket >= 0 {
                _ = Darwin.shutdown(cancellableSocket, SHUT_RDWR)
            }
        }
    }

    private func setCancellableSocket(_ socket: Int32) {
        cancellationLock.withLock { cancellableSocket = socket }
    }
}

/// Bridges a direct-tcpip channel into a normal file descriptor for the next
/// libssh2 session. All calls touching the hop's libssh2 session are confined
/// to this queue.
private nonisolated final class SSHChannelSocketBridge: @unchecked Sendable {
    public let clientSocket: Int32
    private let queue = DispatchQueue(label: "com.akinokaede.termind.ssh.route-bridge")
    private var transportSocket: Int32
    private var session: OpaquePointer?
    private let buffer: SSHConnectionBuffer
    private let stream: SSHStreamPump
    private var transportEvents: SSHSocketEvents?
    private var socketEvents: SSHSocketEvents?
    private var timer: (any DispatchSourceTimer)?
    private var scratch = [UInt8](repeating: 0, count: 32 * 1024)
    private var isClosed = false
    private var scheduled = false
    private var keepaliveDue = true

    public init(
        transportSocket: Int32, session: OpaquePointer, channel: OpaquePointer,
        timeout: TimeInterval
    ) throws {
        var pair: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            _ = libssh2_channel_free(channel)
            _ = libssh2_session_free(session)
            Darwin.close(transportSocket)
            throw TermindSSHError.socket(String(cString: strerror(errno)))
        }
        self.transportSocket = transportSocket
        self.session = session
        buffer = SSHConnectionBuffer(libssh2Session: session)
        stream = SSHStreamPump(socket: pair[0], channel: channel)
        clientSocket = pair[1]

        var yes: Int32 = 1
        for descriptor in pair {
            SSHForwardingTuning.current.configureBridgeSocket(descriptor)
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &yes,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        var interval = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(
            clientSocket, SOL_SOCKET, SO_RCVTIMEO, &interval,
            socklen_t(MemoryLayout<timeval>.size)
        )
        setsockopt(
            clientSocket, SOL_SOCKET, SO_SNDTIMEO, &interval,
            socklen_t(MemoryLayout<timeval>.size)
        )
        let flags = fcntl(stream.socket, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(stream.socket, F_SETFL, flags | O_NONBLOCK) }
        libssh2_session_set_blocking(session, 0)

        libssh2_keepalive_config(session, 0, 20)
        queue.async { [self] in startEvents() }
    }

    private func startEvents() {
        guard !isClosed else { return }
        transportEvents = SSHSocketEvents(socket: transportSocket, queue: queue) { [weak self] in self?.schedule() }
        socketEvents = SSHSocketEvents(socket: stream.socket, queue: queue) { [weak self] in self?.schedule() }
        transportEvents?.update(read: true, write: false)
        socketEvents?.update(read: true, write: false)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 20, repeating: .seconds(20), leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            self?.keepaliveDue = true
            self?.schedule()
        }
        timer = source
        source.resume()
        schedule()
    }

    public func close() { queue.sync { closeOnQueue() } }

    private func schedule() {
        guard !isClosed, !scheduled else { return }
        scheduled = true
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.scheduled = false
            self.pump()
        }
    }

    private func pump() {
        guard !isClosed, let session else { return }
        let deadline = DispatchTime.now().uptimeNanoseconds + SSHForwardingTuning.current.sliceNanoseconds
        buffer.beginPass(deadline: deadline)
        do {
            try buffer.flush(socket: transportSocket)
            if buffer.isBackpressured {
                transportEvents?.update(read: false, write: true)
                socketEvents?.update(read: false, write: stream.socketWriteBlocked)
                return
            }
            let progressed = try stream.pump(session: session, scratch: &scratch, deadline: deadline)
            if stream.finished {
                closeOnQueue()
                return
            }
            if keepaliveDue {
                var next: Int32 = 0
                let result = libssh2_keepalive_send(session, &next)
                if result == LIBSSH2_ERROR_EAGAIN {
                    stream.blocked(session)
                } else if result < 0 {
                    closeOnQueue()
                    return
                } else {
                    keepaliveDue = false
                }
            }
            try buffer.flush(socket: transportSocket)
            socketEvents?.update(read: stream.wantsSocketRead, write: stream.socketWriteBlocked)
            transportEvents?.update(
                read: !buffer.isBackpressured && (stream.wantsChannelRead || !stream.toChannel.isEmpty),
                write: buffer.wantsWrite || stream.blockDirections & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0)
            if progressed || stream.yielded || buffer.exhaustedReadBudget { schedule() }
        } catch { closeOnQueue() }
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        let local = stream.socket
        stream.socket = -1
        if let socketEvents { socketEvents.cancel { Darwin.close(local) } } else { Darwin.close(local) }
        socketEvents = nil
        let remote = transportSocket
        transportSocket = -1
        _ = Darwin.shutdown(remote, SHUT_RDWR)
        if let session { buffer.dispose(libssh2Session: session) }
        session = nil
        stream.channel = nil
        if let transportEvents { transportEvents.cancel { Darwin.close(remote) } } else { Darwin.close(remote) }
        transportEvents = nil
    }
}

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
        keyboardInteractive: SSHKeyboardInteractiveHandler? = nil
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
                try await queue.perform {
                    try state.openFirst(
                        destinationHost: host, destinationPort: port,
                        destinationProxy: proxy, jumps: jumps, timeout: timeout
                    )
                }
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
                        try await SSHSessionWorker.authorizeHostKey(
                            hostID: hop.id, observed: observed,
                            expected: hop.expectedHostKeys,
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
            try SSHSessionWorker.performHandshake(
                session, socket: socket,
                peer: SSHSocketConnector.peerDescription(
                    socket: socket, fallbackHost: hop.host, port: hop.port
                ),
                timeout: timeout
            )
            let observed = try SSHSessionWorker.observation(
                host: hop.host, port: hop.port, session: session
            )
            try SSHSessionWorker.validateHostKey(observed, expected: hop.expectedHostKeys)
            progress?(.authenticating(hop.id))
            try SSHSessionWorker.authenticate(
                username: hop.username, credentials: hop.credentials, session: session
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
        try SSHSessionWorker.performHandshake(
            session, socket: currentSocket,
            peer: SSHSocketConnector.peerDescription(
                socket: currentSocket, fallbackHost: hop.host, port: hop.port
            ),
            timeout: timeout
        )
        return try SSHSessionWorker.observation(
            host: hop.host, port: hop.port, session: session
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
        try SSHSessionWorker.authenticate(
            username: hop.username, credentials: hop.credentials,
            session: session,
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
                try SSHSocketConnector.negotiate(
                    socket: currentSocket, host: nextHost,
                    port: nextPort, proxy: nextProxy
                )
            } catch {
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
    private var pumpSocket: Int32
    private var session: OpaquePointer?
    private var channel: OpaquePointer?
    private var timer: (any DispatchSourceTimer)?
    private var toChannel = Data()
    private var toSocket = Data()
    private var socketEOF = false
    private var channelEOF = false
    private var channelWriteClosed = false
    private var isClosed = false

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
        self.channel = channel
        pumpSocket = pair[0]
        clientSocket = pair[1]

        var yes: Int32 = 1
        for descriptor in pair {
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
        let flags = fcntl(pumpSocket, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(pumpSocket, F_SETFL, flags | O_NONBLOCK) }
        libssh2_session_set_blocking(session, 0)

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.pump() }
        timer = source
        source.resume()
    }

    public func close() {
        queue.sync { closeOnQueue() }
    }

    private func pump() {
        guard !isClosed, let session, let channel else { return }
        let highWaterMark = 2 * 1024 * 1024

        if !socketEOF, toChannel.count < highWaterMark {
            var bytes = [UInt8](repeating: 0, count: 32 * 1024)
            let count = Darwin.recv(pumpSocket, &bytes, bytes.count, 0)
            if count > 0 {
                toChannel.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                socketEOF = true
            } else if errno != EAGAIN && errno != EWOULDBLOCK {
                closeOnQueue()
                return
            }
        }

        while !toChannel.isEmpty {
            let written = toChannel.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                return libssh2_channel_write_ex(channel, 0, base, bytes.count)
            }
            if written > 0 {
                toChannel.removeFirst(written)
            } else if written == LIBSSH2_ERROR_EAGAIN {
                break
            } else {
                closeOnQueue()
                return
            }
        }
        if socketEOF, toChannel.isEmpty, !channelWriteClosed {
            let result = libssh2_channel_send_eof(channel)
            if result == 0 {
                channelWriteClosed = true
            } else if result != LIBSSH2_ERROR_EAGAIN {
                closeOnQueue()
                return
            }
        }

        if toSocket.count < highWaterMark {
            var bytes = [CChar](repeating: 0, count: 32 * 1024)
            while toSocket.count < highWaterMark {
                let count = libssh2_channel_read_ex(channel, 0, &bytes, bytes.count)
                if count > 0 {
                    toSocket.append(Data(bytes: bytes, count: count))
                } else if count == LIBSSH2_ERROR_EAGAIN || count == 0 {
                    break
                } else {
                    closeOnQueue()
                    return
                }
            }
        }
        if libssh2_channel_eof(channel) == 1 { channelEOF = true }

        while !toSocket.isEmpty {
            let sent = toSocket.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.send(pumpSocket, base, bytes.count, 0)
            }
            if sent > 0 {
                toSocket.removeFirst(sent)
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                closeOnQueue()
                return
            }
        }
        if channelEOF && toSocket.isEmpty {
            _ = Darwin.shutdown(pumpSocket, SHUT_WR)
        }
        var next = Int32(0)
        _ = libssh2_keepalive_send(session, &next)
    }

    private func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        timer?.cancel()
        timer = nil
        if pumpSocket >= 0 {
            Darwin.close(pumpSocket)
            pumpSocket = -1
        }
        if let channel {
            _ = libssh2_channel_close(channel)
            _ = libssh2_channel_free(channel)
            self.channel = nil
        }
        if let session {
            _ = libssh2_session_disconnect_ex(
                session, SSH_DISCONNECT_BY_APPLICATION, "Termind closed the jump route", ""
            )
            _ = libssh2_session_free(session)
            self.session = nil
        }
        if transportSocket >= 0 {
            Darwin.close(transportSocket)
            transportSocket = -1
        }
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation
import TermindApplication

/// Adapts the ET library's TCP-only endpoint API to our routed socket owner.
/// Socket ownership and bounded queues stay on one serial queue, including cancellation.
nonisolated final class TerminalTCPBridge: @unchecked Sendable {
    typealias Open = ResumableTerminalClient.RouteFactory
    let port: UInt16
    private let queue = DispatchQueue(label: "com.akinokaede.termind.terminal-tcp-bridge")
    private let open: Open
    private let reporter: TerminalRouteReporter?
    private var routeAttemptID: UUID?
    private var listener: Int32
    private var local: Int32 = -1
    private var remote: SSHRoutedSocket?
    private var timer: (any DispatchSourceTimer)?
    private var opening: Task<Void, Never>?
    private var generation = UUID()
    private var toLocal = Data()
    private var toRemote = Data()
    private var localEOF = false
    private var remoteEOF = false
    private var closed = false
    private var openingBlocked = false

    init(
        open: @escaping Open, initial: SSHRoutedSocket? = nil,
        reporter: TerminalRouteReporter? = nil, initialAttemptID: UUID? = nil
    ) throws {
        self.open = open
        self.reporter = reporter
        self.routeAttemptID = initialAttemptID
        self.remote = initial
        if let initial { Self.configure(initial.socket) }
        listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOBUFS) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let fd = listener
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        port = UInt16(bigEndian: address.sin_port)
        Self.configure(fd)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
    }

    deinit {
        if let routeAttemptID { reporter?.retire(attemptID: routeAttemptID) }
        timer?.cancel()
        opening?.cancel()
        if listener >= 0 { Darwin.close(listener) }
        if local >= 0 { Darwin.close(local) }
        remote?.close()
    }

    func close() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                closed = true
                timer?.cancel()
                timer = nil
                retire()
                if listener >= 0 {
                    Darwin.close(listener)
                    listener = -1
                }
                continuation.resume()
            }
        }
    }

    func retry() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.openingBlocked = false
                continuation.resume()
            }
        }
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private func retire() {
        generation = UUID()
        if let routeAttemptID { reporter?.retire(attemptID: routeAttemptID) }
        routeAttemptID = nil
        opening?.cancel()
        opening = nil
        if local >= 0 {
            Darwin.close(local)
            local = -1
        }
        remote?.close()
        remote = nil
        toLocal.removeAll()
        toRemote.removeAll()
        localEOF = false
        remoteEOF = false
    }

    private func pump() {
        guard !closed else { return }
        let accepted = Darwin.accept(listener, nil, nil)
        if accepted >= 0 {
            if openingBlocked {
                Darwin.close(accepted)
                return
            }
            if local >= 0, remote != nil { retire() }
            if local >= 0 { Darwin.close(local) }
            local = accepted
            Self.configure(accepted)
            toLocal.removeAll()
            toRemote.removeAll()
            if remote == nil, opening == nil { startOpening() }
        }
        guard local >= 0, let remote else { return }
        guard Self.move(from: local, to: remote.socket, buffer: &toRemote, eof: &localEOF),
            Self.move(from: remote.socket, to: local, buffer: &toLocal, eof: &remoteEOF)
        else {
            retire()
            return
        }
        if localEOF && remoteEOF { retire() }
    }

    private func startOpening() {
        let token = generation
        let attemptID = reporter?.begin()
        routeAttemptID = attemptID
        let progress: SSHRouteProgressHandler = { [weak self] event in
            guard let self else { return }
            queue.async {
                guard !self.closed, self.generation == token, let attemptID else { return }
                self.reporter?.receive(event, attemptID: attemptID)
            }
        }
        opening = Task { [weak self, open] in
            do {
                let socket = try await open(progress)
                guard let self else {
                    socket.close()
                    return
                }
                queue.async {
                    guard !self.closed, self.generation == token else {
                        socket.close()
                        return
                    }
                    Self.configure(socket.socket)
                    self.remote = socket
                    self.opening = nil
                    if let attemptID { self.reporter?.ready(attemptID: attemptID) }
                }
            } catch {
                guard let self else { return }
                let sshError = error as? TermindSSHError
                let blocksRetry =
                    error is CancellationError || error is SSHInteractionRequired
                    || sshError?.isLocalAuthenticationRequirement == true
                    || sshError?.shouldRequestAuthentication == true
                    || sshError?.shouldRequestHostKey == true || sshError?.isHostKeyChanged == true
                queue.async {
                    guard self.generation == token else { return }
                    self.openingBlocked = blocksRetry
                    self.retire()
                }
            }
        }
    }

    private static func move(from input: Int32, to output: Int32, buffer: inout Data, eof: inout Bool) -> Bool {
        guard !eof else { return true }
        if buffer.isEmpty {
            var bytes = [UInt8](repeating: 0, count: 32_768)
            let count = Darwin.recv(input, &bytes, bytes.count, 0)
            if count == 0 {
                eof = true
                _ = Darwin.shutdown(output, SHUT_WR)
                return true
            }
            if count < 0 { return errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        let sent = buffer.withUnsafeBytes { Darwin.send(output, $0.baseAddress, $0.count, 0) }
        if sent > 0 { buffer.removeFirst(sent) }
        return sent >= 0 || errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR
    }
}

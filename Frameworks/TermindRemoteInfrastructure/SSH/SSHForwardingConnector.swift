// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Darwin
import Foundation

/// Forwarded target connections must never block the queue that services SSH.
/// Only DNS uses blocking workers (at most four); connect and its overall
/// five-second deadline use readiness events on the owning session queue.
nonisolated final class SSHForwardingConnector: @unchecked Sendable {
    private struct Address: Sendable {
        let family: Int32
        let type: Int32
        let proto: Int32
        let bytes: Data
    }

    private static let resolver: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.akinokaede.termind.forwarding-dns"
        queue.maxConcurrentOperationCount = 4
        return queue
    }()

    private let queue: DispatchQueue
    private var completion: (@Sendable (Result<Int32, any Error>) -> Void)?
    private var addresses: [Address] = []
    private var socket: Int32 = -1
    private var events: SSHSocketEvents?
    private var deadline: (any DispatchSourceTimer)?
    private var resolution: BlockOperation?
    private var finished = false
    private var cancelled = false

    init(queue: DispatchQueue, completion: @escaping @Sendable (Result<Int32, any Error>) -> Void) {
        self.queue = queue
        self.completion = completion
    }

    func start(host: String, port: Int) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5)
        timer.setEventHandler { [weak self] in self?.finish(.failure(POSIXError(.ETIMEDOUT))) }
        timer.resume()
        deadline = timer
        // Numeric targets do not need a resolver worker or a thread-pool hop.
        let numeric = Self.resolve(host: host, port: port, flags: AI_NUMERICHOST)
        if !numeric.isEmpty {
            addresses = numeric
            tryNext()
            return
        }
        let operation = BlockOperation { [weak self] in
            let resolved = Self.resolve(host: host, port: port, flags: 0)
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                self.resolution = nil
                self.addresses = resolved
                self.tryNext()
            }
        }
        resolution = operation
        Self.resolver.addOperation(operation)
    }

    private static func resolve(host: String, port: Int, flags: Int32) -> [Address] {
        var hints = addrinfo()
        hints.ai_flags = flags
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [Address] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor?.pointee {
            addresses.append(
                Address(
                    family: info.ai_family, type: info.ai_socktype, proto: info.ai_protocol,
                    bytes: Data(bytes: info.ai_addr, count: Int(info.ai_addrlen))))
            cursor = info.ai_next
        }
        return addresses
    }

    func cancel() {
        cancelled = true
        completion = nil
        finish(.failure(CancellationError()))
    }

    private func tryNext() {
        guard !finished else { return }
        guard !addresses.isEmpty else {
            finish(.failure(POSIXError(.ECONNREFUSED)))
            return
        }
        let address = addresses.removeFirst()
        let candidate = Darwin.socket(address.family, address.type, address.proto)
        guard candidate >= 0 else {
            tryNext()
            return
        }
        socket = candidate
        var yes: Int32 = 1
        _ = setsockopt(candidate, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(candidate, F_GETFL, 0)
        guard flags >= 0, fcntl(candidate, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(candidate)
            socket = -1
            tryNext()
            return
        }
        let result = address.bytes.withUnsafeBytes {
            Darwin.connect(candidate, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t($0.count))
        }
        if result == 0 {
            finish(.success(candidate))
            return
        }
        guard errno == EINPROGRESS else {
            Darwin.close(candidate)
            socket = -1
            tryNext()
            return
        }
        events = SSHSocketEvents(socket: candidate, queue: queue) { [weak self] in self?.connected() }
        events?.update(read: false, write: true)
    }

    private func connected() {
        guard !finished else { return }
        var error: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        if getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0 {
            finish(.success(socket))
        } else {
            let descriptor = socket
            socket = -1
            events?.cancel { [self] in
                Darwin.close(descriptor)
                tryNext()
            }
            events = nil
        }
    }

    private func finish(_ result: Result<Int32, any Error>) {
        guard !finished else { return }
        finished = true
        resolution?.cancel()
        resolution = nil
        deadline?.cancel()
        deadline = nil
        let descriptor = socket
        socket = -1
        let deliver: @Sendable () -> Void = { [self] in
            if case .failure = result, descriptor >= 0 { Darwin.close(descriptor) }
            if cancelled {
                if case .success(let opened) = result { Darwin.close(opened) }
            } else {
                completion?(result)
            }
            completion = nil
        }
        if let events {
            events.cancel(then: deliver)
            self.events = nil
        } else {
            deliver()
        }
    }
}

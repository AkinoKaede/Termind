// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Server-authored authentication data. Neither challenges nor answers belong
/// in an Agent transcript, connection log, or persistent credential store.
public nonisolated struct SSHKeyboardInteractiveChallenge: Identifiable, Hashable, Sendable {
    public struct Prompt: Hashable, Sendable {
        public var text: String
        public var echo: Bool

        public init(text: String, echo: Bool) {
            self.text = text
            self.echo = echo
        }
    }

    public var id: UUID
    public var connectionID: UUID
    public var hostID: UUID
    public var hostname: String
    public var port: Int
    public var username: String
    public var round: Int
    public var name: String
    public var instruction: String
    public var prompts: [Prompt]
    /// A Tailscale SSH banner needs browser approval, not keyboard-interactive credentials.
    public var isTailscaleApproval: Bool
    public var isInformational: Bool { prompts.isEmpty && !isTailscaleApproval }

    public var tailscaleApprovalURL: URL? {
        guard isTailscaleApproval else { return nil }
        return instruction.split(whereSeparator: \.isWhitespace).compactMap { word in
            guard let url = URL(string: String(word)), url.scheme == "https", url.host != nil,
                url.user == nil, url.password == nil
            else { return nil as URL? }
            return url
        }.first
    }

    public var address: String {
        let host = hostname.contains(":") ? "[\(hostname)]" : hostname
        return "\(username)@\(host):\(port)"
    }

    public init(
        id: UUID = UUID(), connectionID: UUID, hostID: UUID, hostname: String,
        port: Int, username: String, round: Int, name: String, instruction: String,
        prompts: [Prompt], isTailscaleApproval: Bool = false
    ) {
        self.id = id
        self.connectionID = connectionID
        self.hostID = hostID
        self.hostname = hostname
        self.port = port
        self.username = username
        self.round = round
        self.name = name
        self.instruction = instruction
        self.prompts = prompts
        self.isTailscaleApproval = isTailscaleApproval
    }
}

/// Tailscale approval stays presented while the transport waits for the server.
/// Handlers must dismiss their own prompt on task cancellation, including when
/// the transport retires the presentation after successful authentication.
public typealias SSHKeyboardInteractiveHandler =
    @Sendable (SSHKeyboardInteractiveChallenge) async throws -> [String]

/// An operation-owned queue can also be retained by an app for independent
/// transfers. Cancellation removes exactly the requesting connection's prompt.
@Observable
public final class SSHKeyboardInteractiveQueue {
    public private(set) var pending: [SSHKeyboardInteractiveChallenge] = []
    private var waiters: [UUID: CheckedContinuation<[String], any Error>] = [:]

    public var current: SSHKeyboardInteractiveChallenge? { pending.first }

    public init() {}

    public nonisolated var handler: SSHKeyboardInteractiveHandler {
        { [weak self] challenge in
            guard let self else { throw CancellationError() }
            return try await self.request(challenge)
        }
    }

    public func request(_ challenge: SSHKeyboardInteractiveChallenge) async throws -> [String] {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[challenge.id] = continuation
                pending.append(challenge)
                if challenge.isInformational {
                    Task { [weak self] in
                        await Task.yield()
                        self?.respond(challenge.id, answers: [])
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(challenge.id) }
        }
    }

    public func respond(_ id: UUID, answers: [String]) {
        guard let challenge = pending.first(where: { $0.id == id }),
            answers.count == challenge.prompts.count
        else { return }
        pending.removeAll { $0.id == id }
        waiters.removeValue(forKey: id)?.resume(returning: answers)
    }

    public func cancel(_ id: UUID) {
        pending.removeAll { $0.id == id }
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    public func cancelAll(hostID: UUID? = nil) {
        for challenge in pending where hostID == nil || challenge.hostID == hostID {
            cancel(challenge.id)
        }
    }
}

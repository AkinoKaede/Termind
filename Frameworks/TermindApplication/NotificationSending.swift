// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum NotificationAuthorization: Sendable {
    case notDetermined, allowed, denied
}

public nonisolated enum NotificationTarget: Hashable, Sendable {
    case terminal(UUID)
    case assistant(UUID)
    case transfers

    public var id: UUID? {
        switch self {
        case .terminal(let id), .assistant(let id): id
        case .transfers: nil
        }
    }

    public var kind: String {
        switch self {
        case .terminal: "terminal"
        case .assistant: "assistant"
        case .transfers: "transfers"
        }
    }

    public init?(kind: String, id: String) {
        if kind == "transfers" {
            self = .transfers
            return
        }
        guard let id = UUID(uuidString: id) else { return nil }
        switch kind {
        case "terminal": self = .terminal(id)
        case "assistant": self = .assistant(id)
        default: return nil
        }
    }
}

public nonisolated struct AppNotification: Sendable {
    public let id: String
    public let target: NotificationTarget
    public let title: String
    public let body: String

    public init(id: String = UUID().uuidString, target: NotificationTarget, title: String, body: String) {
        self.id = id
        self.target = target
        self.title = title
        self.body = body
    }
}

@MainActor
public protocol NotificationSending: AnyObject {
    func authorization(request: Bool) async -> NotificationAuthorization
    func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async
    func remove(_ identifiers: [String])
    func setBadgeCount(_ count: Int)
}

extension NotificationSending {
    public func setBadgeCount(_ count: Int) {}
}

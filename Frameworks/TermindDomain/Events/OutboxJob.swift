// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum OutboxJobStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

/// A durable unit of application work. The payload is intentionally opaque to
/// the database layer and decoded by the registered handler.
public nonisolated struct OutboxJob: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var eventID: UUID
    public var handlerID: String
    public var eventType: String
    public var payload: Data
    public var status: OutboxJobStatus
    public var attemptCount: Int
    public var createdAt: Date
    public var nextAttemptAt: Date
    public var lastError: String?

    public init(
        id: UUID = UUID(), eventID: UUID = UUID(), handlerID: String,
        eventType: String, payload: Data, status: OutboxJobStatus = .pending,
        attemptCount: Int = 0, createdAt: Date = Date(),
        nextAttemptAt: Date = Date(), lastError: String? = nil
    ) {
        self.id = id
        self.eventID = eventID
        self.handlerID = handlerID
        self.eventType = eventType
        self.payload = payload
        self.status = status
        self.attemptCount = attemptCount
        self.createdAt = createdAt
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
    }
}

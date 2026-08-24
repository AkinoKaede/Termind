import Foundation

nonisolated enum OutboxJobStatus: String, Codable, Hashable, Sendable {
    case pending
    case running
    case succeeded
    case failed
}

/// A durable unit of application work. The payload is intentionally opaque to
/// the database layer and decoded by the registered handler.
nonisolated struct OutboxJob: Identifiable, Hashable, Sendable {
    var id: UUID
    var eventID: UUID
    var handlerID: String
    var eventType: String
    var payload: Data
    var status: OutboxJobStatus
    var attemptCount: Int
    var createdAt: Date
    var nextAttemptAt: Date
    var lastError: String?

    init(
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

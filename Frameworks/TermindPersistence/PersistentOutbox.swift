import Foundation
import SwiftData
import TermindDomain

@Model
public final class PersistentOutboxJob {
    @Attribute(.unique) public var id: UUID = UUID()
    public var eventID: UUID = UUID()
    public var handlerID = ""
    public var eventType = ""
    public var payload = Data()
    public var status = OutboxJobStatus.pending.rawValue
    public var attemptCount = 0
    public var createdAt = Date(timeIntervalSince1970: 0)
    public var nextAttemptAt = Date(timeIntervalSince1970: 0)
    public var lastError: String?

    public init(_ value: OutboxJob) {
        id = value.id
        apply(value)
    }

    public func apply(_ value: OutboxJob) {
        eventID = value.eventID
        handlerID = value.handlerID
        eventType = value.eventType
        payload = value.payload
        status = value.status.rawValue
        attemptCount = value.attemptCount
        createdAt = value.createdAt
        nextAttemptAt = value.nextAttemptAt
        lastError = value.lastError
    }

    public var value: OutboxJob {
        OutboxJob(
            id: id, eventID: eventID, handlerID: handlerID,
            eventType: eventType, payload: payload,
            status: OutboxJobStatus(rawValue: status) ?? .failed,
            attemptCount: attemptCount, createdAt: createdAt,
            nextAttemptAt: nextAttemptAt, lastError: lastError
        )
    }
}

/// A separate row avoids changing V1 entity layouts while allowing a future
/// repository to hide records that are being removed by a durable saga.
@Model
public final class PersistentPendingDeletion {
    @Attribute(.unique) public var id: UUID = UUID()
    public var entityType = ""
    public var entityID: UUID = UUID()
    public var createdAt = Date(timeIntervalSince1970: 0)

    public init(
        id: UUID = UUID(), entityType: String, entityID: UUID,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entityType = entityType
        self.entityID = entityID
        self.createdAt = createdAt
    }
}

@Model
public final class PersistentDatabaseMetadata {
    @Attribute(.unique) public var key = "repository"
    public var revision: Int64 = 0

    public init(key: String = "repository", revision: Int64 = 0) {
        self.key = key
        self.revision = revision
    }
}

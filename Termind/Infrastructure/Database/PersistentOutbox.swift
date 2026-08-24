import Foundation
import SwiftData

@Model
final class PersistentOutboxJob {
    @Attribute(.unique) var id: UUID = UUID()
    var eventID: UUID = UUID()
    var handlerID = ""
    var eventType = ""
    var payload = Data()
    var status = OutboxJobStatus.pending.rawValue
    var attemptCount = 0
    var createdAt = Date(timeIntervalSince1970: 0)
    var nextAttemptAt = Date(timeIntervalSince1970: 0)
    var lastError: String?

    init(_ value: OutboxJob) {
        id = value.id
        apply(value)
    }

    func apply(_ value: OutboxJob) {
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

    var value: OutboxJob {
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
final class PersistentPendingDeletion {
    @Attribute(.unique) var id: UUID = UUID()
    var entityType = ""
    var entityID: UUID = UUID()
    var createdAt = Date(timeIntervalSince1970: 0)

    init(
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
final class PersistentDatabaseMetadata {
    @Attribute(.unique) var key = "repository"
    var revision: Int64 = 0

    init(key: String = "repository", revision: Int64 = 0) {
        self.key = key
        self.revision = revision
    }
}

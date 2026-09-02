import Foundation
import SwiftData

@MainActor
final class SwiftDataOutboxStore: OutboxStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func enqueue(_ jobs: [OutboxJob]) throws {
        for job in jobs { context.insert(PersistentOutboxJob(job)) }
        try save()
    }

    func nextReady(at date: Date) throws -> OutboxJob? {
        let pending = OutboxJobStatus.pending.rawValue
        var descriptor = FetchDescriptor<PersistentOutboxJob>(
            predicate: #Predicate { $0.status == pending && $0.nextAttemptAt <= date },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.handlerID)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.value
    }

    func markRunning(_ id: OutboxJob.ID) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = OutboxJobStatus.running.rawValue
        job.attemptCount += 1
        job.lastError = nil
        try save()
    }

    func markSucceeded(_ id: OutboxJob.ID) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = OutboxJobStatus.succeeded.rawValue
        job.lastError = nil
        try save()
    }

    func markFailed(_ id: OutboxJob.ID, error: String, retryAt: Date?) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = (retryAt == nil ? OutboxJobStatus.failed : .pending).rawValue
        job.lastError = error
        if let retryAt { job.nextAttemptAt = retryAt }
        try save()
    }

    func resetInterruptedJobs() throws {
        let running = OutboxJobStatus.running.rawValue
        let jobs = try context.fetch(
            FetchDescriptor<PersistentOutboxJob>(predicate: #Predicate { $0.status == running })
        )
        for job in jobs { job.status = OutboxJobStatus.pending.rawValue }
        if !jobs.isEmpty { try save() }
    }

    func retryFailedJob(_ id: OutboxJob.ID) throws {
        guard let job = try persistentJob(id),
            job.status == OutboxJobStatus.failed.rawValue
        else { return }
        job.status = OutboxJobStatus.pending.rawValue
        job.nextAttemptAt = Date()
        job.lastError = nil
        try save()
    }

    private func persistentJob(_ id: UUID) throws -> PersistentOutboxJob? {
        var descriptor = FetchDescriptor<PersistentOutboxJob>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func save() throws {
        try context.savePendingChanges()
    }
}

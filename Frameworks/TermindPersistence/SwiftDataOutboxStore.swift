import Foundation
import SwiftData
import TermindApplication
import TermindDomain

@MainActor
public final class SwiftDataOutboxStore: OutboxStore {
    private let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    public func enqueue(_ jobs: [OutboxJob]) throws {
        for job in jobs { context.insert(PersistentOutboxJob(job)) }
        try save()
    }

    public func nextReady(at date: Date) throws -> OutboxJob? {
        let pending = OutboxJobStatus.pending.rawValue
        var descriptor = FetchDescriptor<PersistentOutboxJob>(
            predicate: #Predicate { $0.status == pending && $0.nextAttemptAt <= date },
            sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.handlerID)]
        )
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first?.value
    }

    public func markRunning(_ id: OutboxJob.ID) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = OutboxJobStatus.running.rawValue
        job.attemptCount += 1
        job.lastError = nil
        try save()
    }

    public func markSucceeded(_ id: OutboxJob.ID) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = OutboxJobStatus.succeeded.rawValue
        job.lastError = nil
        try save()
    }

    public func markFailed(_ id: OutboxJob.ID, error: String, retryAt: Date?) throws {
        guard let job = try persistentJob(id) else { return }
        job.status = (retryAt == nil ? OutboxJobStatus.failed : .pending).rawValue
        job.lastError = error
        if let retryAt { job.nextAttemptAt = retryAt }
        try save()
    }

    public func resetInterruptedJobs() throws {
        let running = OutboxJobStatus.running.rawValue
        let jobs = try context.fetch(
            FetchDescriptor<PersistentOutboxJob>(predicate: #Predicate { $0.status == running })
        )
        for job in jobs { job.status = OutboxJobStatus.pending.rawValue }
        if !jobs.isEmpty { try save() }
    }

    public func retryFailedJob(_ id: OutboxJob.ID) throws {
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

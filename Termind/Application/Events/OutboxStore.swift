import Foundation

@MainActor
protocol OutboxStore: AnyObject {
    func enqueue(_ jobs: [OutboxJob]) throws
    func nextReady(at date: Date) throws -> OutboxJob?
    func markRunning(_ id: OutboxJob.ID) throws
    func markSucceeded(_ id: OutboxJob.ID) throws
    func markFailed(_ id: OutboxJob.ID, error: String, retryAt: Date?) throws
    func resetInterruptedJobs() throws
    func retryFailedJob(_ id: OutboxJob.ID) throws
}

protocol OutboxEventHandler: AnyObject {
    nonisolated var handlerID: String { get }
    func handle(type: String, payload: Data, eventID: UUID) async throws
}

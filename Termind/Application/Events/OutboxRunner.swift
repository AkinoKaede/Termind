import Foundation

/// Executes durable jobs one at a time. Persisted status is the idempotency
/// ledger, and handlers receive the stable event id for their own deduplication.
@MainActor
final class OutboxRunner {
    private let store: any OutboxStore
    private var handlers: [String: any OutboxEventHandler]
    private var task: Task<Void, Never>?
    private let maximumAttempts: Int

    init(
        store: any OutboxStore, handlers: [any OutboxEventHandler] = [],
        maximumAttempts: Int = 5
    ) {
        self.store = store
        self.handlers = Dictionary(uniqueKeysWithValues: handlers.map { ($0.handlerID, $0) })
        self.maximumAttempts = maximumAttempts
    }

    func register(_ handler: any OutboxEventHandler) {
        handlers[handler.handlerID] = handler
    }

    func start() {
        guard task == nil else { return }
        do { try store.resetInterruptedJobs() } catch { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        defer { task = nil }
        while !Task.isCancelled {
            do {
                guard let job = try store.nextReady(at: Date()) else {
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                guard let handler = handlers[job.handlerID] else {
                    try store.markFailed(
                        job.id, error: "No outbox handler is registered for \(job.handlerID).",
                        retryAt: nil
                    )
                    continue
                }
                try store.markRunning(job.id)
                do {
                    try await handler.handle(
                        type: job.eventType, payload: job.payload, eventID: job.eventID
                    )
                    try store.markSucceeded(job.id)
                } catch {
                    let attempt = job.attemptCount + 1
                    let retryAt = attempt >= maximumAttempts
                        ? nil
                        : Date().addingTimeInterval(pow(2, Double(attempt)))
                    try store.markFailed(
                        job.id, error: error.localizedDescription, retryAt: retryAt
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

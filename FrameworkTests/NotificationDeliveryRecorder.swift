import Foundation
import TermindApplication

/// Explicit suspension points for notification delivery tests.
@MainActor
final class NotificationDeliveryRecorder: NotificationSending {
    private let arrivals = AsyncStream<AppNotification>.makeStream()
    private let completions = AsyncStream<Void>.makeStream()
    private var pending: CheckedContinuation<Void, Never>?
    private(set) var sent: [AppNotification] = []
    private(set) var removed: [String] = []
    private(set) var startedCount = 0

    func authorization(request: Bool) async -> NotificationAuthorization { .allowed }
    func send(_ notification: AppNotification, ifCurrent: @escaping @MainActor () -> Bool) async {
        startedCount += 1
        await withCheckedContinuation {
            pending = $0
            arrivals.continuation.yield(notification)
        }
        if !Task.isCancelled, ifCurrent() { sent.append(notification) }
        completions.continuation.yield(())
    }
    func remove(_ identifiers: [String]) { removed.append(contentsOf: identifiers) }
    func nextRequest() async -> AppNotification? {
        var iterator = arrivals.stream.makeAsyncIterator()
        return await iterator.next()
    }
    func finishDelivery() async {
        pending?.resume()
        pending = nil
        var iterator = completions.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

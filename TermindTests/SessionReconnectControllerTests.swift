import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct SessionReconnectControllerTests {
    @Test
    func retriesUseCappedBackoffAndRetainLatestFailure() {
        let clock = ReconnectTestClock()
        let controller = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { clock.value }
        )

        let expectedDelays: [TimeInterval] = [1, 2, 5, 10, 30, 30]
        for (index, expectedDelay) in expectedDelays.enumerated() {
            controller.schedule(after: "failure-\(index + 1)") {}
            #expect(controller.state?.attempt == index + 1)
            #expect(controller.state?.lastError == "failure-\(index + 1)")
            #expect(
                controller.state?.nextRetry.timeIntervalSince(clock.value)
                    == expectedDelay
            )
        }
        controller.stop()
    }

    @Test
    func stableConnectionResetsAttemptCounter() {
        let clock = ReconnectTestClock()
        let controller = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) },
            now: { clock.value }
        )

        controller.schedule(after: "first") {}
        controller.schedule(after: "second") {}
        #expect(controller.state?.attempt == 2)

        controller.markConnected(initial: false)
        clock.advance(by: 61)
        controller.schedule(after: "after stable connection") {}

        #expect(controller.state?.attempt == 1)
        controller.stop()
    }

    @Test
    func retryNowRunsImmediatelyAndStopCancelsFutureRetry() async {
        let controller = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }
        )
        var retryCount = 0
        controller.schedule(after: "offline") { retryCount += 1 }

        controller.retryNow()
        await Task.yield()
        #expect(retryCount == 1)

        controller.stop()
        #expect(controller.state == nil)
        try? await Task.sleep(for: .milliseconds(10))
        #expect(retryCount == 1)
    }
}

private nonisolated final class ReconnectTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000)

    var value: Date { lock.withLock { date } }

    func advance(by interval: TimeInterval) {
        lock.withLock { date.addTimeInterval(interval) }
    }
}

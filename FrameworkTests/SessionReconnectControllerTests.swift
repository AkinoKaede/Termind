// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindApplication
import Testing

@Suite
@MainActor
struct SessionReconnectControllerTests {
    @Test func systemBlockersPreserveIntentAndCannotBeBypassedByRetryNow() async throws {
        let availability = ConnectionRecoveryAvailability()
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        controller.useAvailability(availability)
        defer { controller.stop() }
        availability.setBlocked(true, by: .inactiveSession)
        availability.setBlocked(true, by: .systemSleep)
        var retries = 0
        controller.schedule(after: "offline") { retries += 1 }
        controller.retryNow()
        #expect(retries == 0)
        #expect(controller.state?.phase == .waitingForSystem)

        availability.setBlocked(false, by: .systemSleep)
        availability.requestRecheck()
        #expect(controller.state?.phase == .waitingForSystem)
        #expect(retries == 0)
        availability.setBlocked(false, by: .inactiveSession)
        availability.requestRecheck()
        availability.requestRecheck()
        try await waitForRetry { retries == 1 }
        controller.retryNow()
        availability.requestRecheck()
        #expect(retries == 1)
    }

    @Test func credentialBackoffDoesNotConsumeNetworkAttemptsOrExposeRawErrors() {
        let clock = ReconnectTestClock()
        let controller = SessionReconnectController(
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) }, now: { clock.value })
        defer { controller.stop() }
        controller.schedule(after: "offline") {}
        for delay in [1.0, 2, 5, 10, 30, 30] {
            controller.schedule(after: "raw security error", waitingForCredentials: true) {}
            #expect(controller.state?.attempt == 1)
            #expect(controller.state?.phase == .waitingForCredentials)
            #expect(controller.state?.lastError.isEmpty == true)
            #expect(controller.state?.nextRetry.timeIntervalSince(clock.value) == delay)
        }
        controller.schedule(after: "offline again") {}
        #expect(controller.state?.attempt == 2)
    }

    @Test func credentialsRetryWithoutAnyLifecycleNotification() async throws {
        let controller = SessionReconnectController(policy: ReconnectPolicy(delays: [.zero]))
        defer { controller.stop() }
        var retries = 0
        controller.schedule(after: "", waitingForCredentials: true) { retries += 1 }
        try await waitForRetry { retries == 1 }
    }

    @Test(arguments: [false, true])
    func stopAndSuccessfulConnectionRejectQueuedRecoveryHints(_ connected: Bool) async throws {
        let availability = ConnectionRecoveryAvailability()
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        controller.useAvailability(availability)
        var retries = 0
        controller.schedule(after: "", waitingForCredentials: true) { retries += 1 }
        availability.requestRecheck()
        if connected { controller.markConnected(initial: false) } else { controller.stop() }
        availability.requestRecheck()
        try await Task.sleep(for: .milliseconds(20))
        #expect(retries == 0)
        #expect(controller.state == nil)
    }

    @Test func blockingDuringCountdownDoesNotLoseRetryAndSuccessRemovesWaitState() async throws {
        let availability = ConnectionRecoveryAvailability()
        let controller = SessionReconnectController(sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        controller.useAvailability(availability)
        defer { controller.stop() }
        var retries = 0
        controller.schedule(after: "", waitingForCredentials: true) { retries += 1 }
        availability.setBlocked(true, by: .systemSleep)
        #expect(controller.state?.phase == .waitingForSystem)
        availability.setBlocked(false, by: .systemSleep)
        try await waitForRetry { retries == 1 }
        controller.markConnected(initial: false)
        #expect(controller.state == nil)
    }

    private func waitForRetry(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }

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

    @Test
    func scheduledRetryReturnsToMainActorAfterDetachedSleep() async throws {
        let controller = SessionReconnectController(
            policy: ReconnectPolicy(delays: [.zero]),
            sleep: { _ in await Task.detached(priority: .userInitiated) {}.value }
        )
        defer { controller.stop() }
        var ran = false
        var ranOnMainThread = false

        controller.schedule(after: "offline") {
            ranOnMainThread = Thread.isMainThread
            ran = true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ran, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(ran)
        #expect(ranOnMainThread)
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

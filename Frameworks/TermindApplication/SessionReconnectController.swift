// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated struct ReconnectPolicy: Sendable, Equatable {
    public static let sessionDefault = ReconnectPolicy()

    public var delays: [Duration]
    public var stableResetInterval: TimeInterval

    public init(
        delays: [Duration] = [.seconds(1), .seconds(2), .seconds(5), .seconds(10), .seconds(30)],
        stableResetInterval: TimeInterval = 60
    ) {
        precondition(!delays.isEmpty)
        self.delays = delays
        self.stableResetInterval = stableResetInterval
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        delays[min(max(0, attempt - 1), delays.count - 1)]
    }
}

public nonisolated struct ReconnectState: Equatable, Sendable {
    public enum Phase: Sendable {
        case retrying
        case waitingForSystem
        case waitingForCredentials
    }

    public var attempt: Int
    public var nextRetry: Date
    public var lastError: String
    public var phase: Phase
    public init(attempt: Int, nextRetry: Date, lastError: String, phase: Phase = .retrying) {
        self.attempt = attempt
        self.nextRetry = nextRetry
        self.lastError = lastError
        self.phase = phase
    }

}

/// Owns only retry timing and stale-callback rejection. The session models keep
/// transport construction because they also own authentication and host-key UI.
@MainActor
@Observable
public final class SessionReconnectController {
    public typealias RetryAction = @MainActor @Sendable () -> Void
    public typealias Sleep = @Sendable (Duration) async throws -> Void
    public typealias Now = @Sendable () -> Date

    public private(set) var state: ReconnectState?

    private let policy: ReconnectPolicy
    private let sleep: Sleep
    private let now: Now
    private var retryTask: Task<Void, Never>?
    private var retryAction: RetryAction?
    private var attempts = 0
    private var connectedAt: Date?
    private var generation: UInt64 = 0
    private var availability: ConnectionRecoveryAvailability?
    private var availabilityObservation: UUID?
    private var credentialAttempts = 0
    private var waitingForCredentials = false

    public func useAvailability(_ availability: ConnectionRecoveryAvailability?) {
        guard self.availability !== availability else { return }
        removeAvailabilityObservation()
        self.availability = availability
        if retryAction != nil {
            observeAvailability()
            availabilityChanged()
        }
    }

    public var isSystemAvailable: Bool { availability?.isAvailable != false }

    public init(
        policy: ReconnectPolicy = .sessionDefault,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping Now = Date.init
    ) {
        self.policy = policy
        self.sleep = sleep
        self.now = now
    }

    isolated deinit {
        retryTask?.cancel()
        if let availabilityObservation { availability?.removeObserver(availabilityObservation) }
    }

    public func markConnected(initial: Bool) {
        cancelScheduledRetry()
        generation &+= 1
        removeAvailabilityObservation()
        credentialAttempts = 0
        waitingForCredentials = false
        state = nil
        retryAction = nil
        connectedAt = now()
        if initial { attempts = 0 }
    }

    public func schedule(
        after error: String, waitingForCredentials: Bool = false, retry: @escaping RetryAction
    ) {
        cancelScheduledRetry()
        if let connectedAt,
            now().timeIntervalSince(connectedAt) >= policy.stableResetInterval
        {
            attempts = 0
        }
        connectedAt = nil
        self.waitingForCredentials = waitingForCredentials
        if waitingForCredentials {
            credentialAttempts += 1
        } else if isSystemAvailable {
            attempts += 1
            credentialAttempts = 0
        }
        retryAction = retry
        let delay = policy.delay(forAttempt: waitingForCredentials ? credentialAttempts : attempts)
        state = ReconnectState(
            attempt: attempts,
            nextRetry: now().addingTimeInterval(delay.timeInterval),
            lastError: waitingForCredentials ? "" : error,
            phase: isSystemAvailable ? (waitingForCredentials ? .waitingForCredentials : .retrying) : .waitingForSystem
        )
        observeAvailability()
        if isSystemAvailable { schedule(delay: delay) } else { generation &+= 1 }
    }

    public func retryNow() {
        guard retryAction != nil else { return }
        cancelScheduledRetry()
        generation &+= 1
        runScheduledRetry(expectedGeneration: generation)
    }

    public func stop() {
        cancelScheduledRetry()
        generation &+= 1
        state = nil
        retryAction = nil
        removeAvailabilityObservation()
        attempts = 0
        credentialAttempts = 0
        waitingForCredentials = false
        connectedAt = nil
    }

    /// Pauses retry timing without discarding the attempt counter. Used while
    /// the connection journey waits for credentials or a host-key decision.
    public func pauseForUserInteraction() {
        cancelScheduledRetry()
        generation &+= 1
        state = nil
        retryAction = nil
        removeAvailabilityObservation()
    }

    private func schedule(delay: Duration) {
        generation &+= 1
        let expectedGeneration = generation
        let sleep = sleep
        retryTask = Task.detached { [weak self, sleep] in
            do { try await sleep(delay) } catch { return }
            await self?.runScheduledRetry(expectedGeneration: expectedGeneration)
        }
    }

    private func runScheduledRetry(expectedGeneration: UInt64) {
        guard generation == expectedGeneration, let retryAction else { return }
        guard isSystemAvailable else {
            state?.phase = .waitingForSystem
            return
        }
        // Consume before invoking: lifecycle hints and Retry Now cannot duplicate an in-flight attempt.
        self.retryAction = nil
        removeAvailabilityObservation()
        cancelScheduledRetry()
        generation &+= 1
        state?.phase = waitingForCredentials ? .waitingForCredentials : .retrying
        retryAction()
    }

    private func observeAvailability() {
        guard availabilityObservation == nil else { return }
        availabilityObservation = availability?.observe { [weak self] in self?.availabilityChanged() }
    }

    private func removeAvailabilityObservation() {
        if let availabilityObservation { availability?.removeObserver(availabilityObservation) }
        availabilityObservation = nil
    }

    private func availabilityChanged() {
        guard retryAction != nil else { return }
        cancelScheduledRetry()
        generation &+= 1
        if !isSystemAvailable {
            state?.phase = .waitingForSystem
            return
        }
        state?.phase = waitingForCredentials ? .waitingForCredentials : .retrying
        state?.nextRetry = now()
        // Hop once to coalesce wake/session/application notifications from the same turn.
        let expectedGeneration = generation
        retryTask = Task { [weak self] in
            await Task.yield()
            self?.runScheduledRetry(expectedGeneration: expectedGeneration)
        }
    }

    private func cancelScheduledRetry() {
        retryTask?.cancel()
        retryTask = nil
    }
}
nonisolated

    extension Duration
{
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

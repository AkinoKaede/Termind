import Foundation
import TermindDomain

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
    public var attempt: Int
    public var nextRetry: Date
    public var lastError: String
    public init(attempt: Int, nextRetry: Date, lastError: String) {
        self.attempt = attempt
        self.nextRetry = nextRetry
        self.lastError = lastError
    }

}

/// Owns only retry timing and stale-callback rejection. The session models keep
/// transport construction because they also own authentication and host-key UI.
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

    public init(
        policy: ReconnectPolicy = .sessionDefault,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        now: @escaping Now = Date.init
    ) {
        self.policy = policy
        self.sleep = sleep
        self.now = now
    }

    public func markConnected(initial: Bool) {
        cancelScheduledRetry()
        state = nil
        retryAction = nil
        connectedAt = now()
        if initial { attempts = 0 }
    }

    public func schedule(after error: String, retry: @escaping RetryAction) {
        cancelScheduledRetry()
        if let connectedAt,
            now().timeIntervalSince(connectedAt) >= policy.stableResetInterval
        {
            attempts = 0
        }
        connectedAt = nil
        attempts += 1
        retryAction = retry
        let delay = policy.delay(forAttempt: attempts)
        state = ReconnectState(
            attempt: attempts,
            nextRetry: now().addingTimeInterval(delay.timeInterval),
            lastError: error
        )
        schedule(delay: delay)
    }

    public func retryNow() {
        guard let retryAction else { return }
        cancelScheduledRetry()
        generation &+= 1
        let expectedGeneration = generation
        retryTask = Task { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            retryAction()
        }
    }

    public func stop() {
        cancelScheduledRetry()
        generation &+= 1
        state = nil
        retryAction = nil
        attempts = 0
        connectedAt = nil
    }

    /// Pauses retry timing without discarding the attempt counter. Used while
    /// the connection journey waits for credentials or a host-key decision.
    public func pauseForUserInteraction() {
        cancelScheduledRetry()
        generation &+= 1
        state = nil
        retryAction = nil
    }

    private func schedule(delay: Duration) {
        generation &+= 1
        let expectedGeneration = generation
        let sleep = sleep
        retryTask = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard let self, self.generation == expectedGeneration,
                let retryAction = self.retryAction
            else { return }
            retryAction()
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

import Foundation
import TermindDomain

/// One live preference shared by every SSH connection created by a coordinator.
/// Each connection receives its own budget; only the configured ceiling is global.
public nonisolated final class SSHMaxSessionsPolicy: @unchecked Sendable {
    private final class WeakBudget: @unchecked Sendable {
        weak var value: SSHChannelBudget?
        init(_ value: SSHChannelBudget) { self.value = value }
    }

    private let lock = NSLock()
    private var maximum: Int
    private var budgets: [UUID: WeakBudget] = [:]

    public init(preferences: SSHPreferences = SSHPreferences()) {
        maximum = preferences.normalized.maxSessions
    }

    public func update(_ preferences: SSHPreferences) {
        let maximum = preferences.normalized.maxSessions
        let active = lock.withLock { () -> [SSHChannelBudget] in
            self.maximum = maximum
            budgets = budgets.filter { $0.value.value != nil }
            return budgets.values.compactMap(\.value)
        }
        for budget in active { budget.updateMaximum(maximum) }
    }

    func makeBudget() -> SSHChannelBudget {
        let id = UUID()
        return lock.withLock {
            let budget = SSHChannelBudget(maximum: maximum)
            budgets[id] = WeakBudget(budget)
            return budget
        }
    }
}

nonisolated final class SSHChannelLease: @unchecked Sendable {
    private let lock = NSLock()
    private weak var budget: SSHChannelBudget?

    init(budget: SSHChannelBudget) { self.budget = budget }

    func release() {
        let budget = lock.withLock { () -> SSHChannelBudget? in
            defer { self.budget = nil }
            return self.budget
        }
        budget?.release()
    }

    deinit { release() }
}

/// FIFO admission for shell, exec, and subsystem channels on one SSH connection.
nonisolated final class SSHChannelBudget: @unchecked Sendable {
    private final class CancellationRegistration: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var action: (@Sendable () -> Void)?

        func install(_ action: @escaping @Sendable () -> Void) {
            let callNow = lock.withLock { () -> Bool in
                guard !cancelled else { return true }
                self.action = action
                return false
            }
            if callNow { action() }
        }

        func cancel() {
            let action = lock.withLock { () -> (@Sendable () -> Void)? in
                cancelled = true
                defer { self.action = nil }
                return self.action
            }
            action?()
        }
    }

    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<SSHChannelLease, any Error>
        var cancellation: TransferCancellationToken?
        var cancellationObserver: UUID?
    }

    private let lock = NSLock()
    private var maximum: Int
    private var active = 0
    private var waiters: [Waiter] = []
    private var closed = false

    init(maximum: Int) { self.maximum = maximum }

    func acquire(cancellation: TransferCancellationToken? = nil) async throws -> SSHChannelLease {
        if cancellation?.isCancelled == true { throw CancellationError() }
        let id = UUID()
        let registration = CancellationRegistration()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SSHChannelLease, any Error>) in
                var immediate: Result<SSHChannelLease, any Error>?
                var queued = false
                lock.withLock {
                    if closed || Task.isCancelled || cancellation?.isCancelled == true {
                        immediate = .failure(CancellationError())
                    } else if active < maximum && waiters.isEmpty {
                        active += 1
                        immediate = .success(SSHChannelLease(budget: self))
                    } else {
                        waiters.append(
                            Waiter(
                                id: id, continuation: continuation,
                                cancellation: cancellation, cancellationObserver: nil))
                        queued = true
                    }
                }
                if let immediate { continuation.resume(with: immediate) }
                guard queued else { return }
                registration.install { [weak self] in self?.cancelWaiter(id) }
                guard let cancellation else { return }
                let observer = cancellation.observeCancellation { [weak self] in self?.cancelWaiter(id) }
                let retained = lock.withLock { () -> Bool in
                    guard let index = waiters.firstIndex(where: { $0.id == id }) else { return false }
                    waiters[index].cancellationObserver = observer
                    return true
                }
                if !retained { cancellation.removeObserver(observer) }
            }
        } onCancel: {
            registration.cancel()
        }
    }

    func updateMaximum(_ maximum: Int) {
        let resumed = lock.withLock { () -> [Waiter] in
            self.maximum = maximum
            return admitWaiters()
        }
        resume(resumed)
    }

    func close() {
        let cancelled = lock.withLock { () -> [Waiter] in
            guard !closed else { return [] }
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        for waiter in cancelled {
            removeCancellationObserver(waiter)
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    fileprivate func release() {
        let resumed = lock.withLock { () -> [Waiter] in
            active = max(0, active - 1)
            return admitWaiters()
        }
        resume(resumed)
    }

    private func cancelWaiter(_ id: UUID) {
        let waiter = lock.withLock { () -> Waiter? in
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index)
        }
        guard let waiter else { return }
        removeCancellationObserver(waiter)
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Called only while `lock` is held.
    private func admitWaiters() -> [Waiter] {
        guard !closed else { return [] }
        var admitted: [Waiter] = []
        while active < maximum, !waiters.isEmpty {
            active += 1
            admitted.append(waiters.removeFirst())
        }
        return admitted
    }

    private func resume(_ waiters: [Waiter]) {
        for waiter in waiters {
            removeCancellationObserver(waiter)
            waiter.continuation.resume(returning: SSHChannelLease(budget: self))
        }
    }

    private func removeCancellationObserver(_ waiter: Waiter) {
        if let observer = waiter.cancellationObserver {
            waiter.cancellation?.removeObserver(observer)
        }
    }
}

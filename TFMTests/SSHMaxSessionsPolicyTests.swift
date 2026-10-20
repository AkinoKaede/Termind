// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import Testing

@testable import TermindRemoteInfrastructure

@Suite
struct SSHMaxSessionsPolicyTests {
    @Test
    func defaultLimitQueuesTheEleventhChannelUntilOneCloses() async throws {
        let policy = SSHMaxSessionsPolicy()
        let budget = policy.makeBudget()
        var leases: [SSHChannelLease] = []
        for _ in 0..<SSHPreferences.defaultMaxSessions {
            leases.append(try await budget.acquire())
        }
        let probe = ChannelAdmissionProbe()
        let waiting = Task {
            let lease = try await budget.acquire()
            await probe.admit(11)
            return lease
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.values.isEmpty)

        leases.removeFirst().release()
        await waitUntil { await probe.values == [11] }
        let admitted = try await waiting.value
        admitted.release()
        for lease in leases { lease.release() }
    }

    @Test
    func loweringAndRaisingTheLiveLimitNeverRevokesActiveChannels() async throws {
        let policy = SSHMaxSessionsPolicy(preferences: SSHPreferences(maxSessions: 3))
        let budget = policy.makeBudget()
        let first = try await budget.acquire()
        let second = try await budget.acquire()
        let third = try await budget.acquire()
        policy.update(SSHPreferences(maxSessions: 1))

        let probe = ChannelAdmissionProbe()
        let waiting = Task {
            let lease = try await budget.acquire()
            await probe.admit(4)
            return lease
        }
        first.release()
        second.release()
        for _ in 0..<20 { await Task.yield() }
        #expect(await probe.values.isEmpty)

        policy.update(SSHPreferences(maxSessions: 2))
        await waitUntil { await probe.values == [4] }
        let admitted = try await waiting.value
        third.release()
        admitted.release()
    }

    @Test
    func cancellationRemovesAWaiterWithoutLeakingCapacity() async throws {
        let policy = SSHMaxSessionsPolicy(preferences: SSHPreferences(maxSessions: 1))
        let budget = policy.makeBudget()
        let active = try await budget.acquire()
        let cancellation = TransferCancellationToken()
        let cancelled = Task { try await budget.acquire(cancellation: cancellation) }
        for _ in 0..<20 { await Task.yield() }
        cancellation.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        active.release()
        let replacement = try await budget.acquire()
        replacement.release()
    }

    @Test
    func queuedChannelsResumeInFIFOOrder() async throws {
        let policy = SSHMaxSessionsPolicy(preferences: SSHPreferences(maxSessions: 1))
        let budget = policy.makeBudget()
        let active = try await budget.acquire()
        let probe = ChannelAdmissionProbe()
        let first = Task {
            let lease = try await budget.acquire()
            await probe.admit(1)
            return lease
        }
        for _ in 0..<20 { await Task.yield() }
        let second = Task {
            let lease = try await budget.acquire()
            await probe.admit(2)
            return lease
        }
        for _ in 0..<20 { await Task.yield() }

        active.release()
        await waitUntil { await probe.values == [1] }
        let firstLease = try await first.value
        firstLease.release()
        await waitUntil { await probe.values == [1, 2] }
        let secondLease = try await second.value
        secondLease.release()
    }

    @Test
    func separateTransportsHaveIndependentBudgets() async throws {
        let policy = SSHMaxSessionsPolicy(preferences: SSHPreferences(maxSessions: 1))
        let first = policy.makeBudget()
        let second = policy.makeBudget()
        let firstLease = try await first.acquire()
        let secondLease = try await second.acquire()
        firstLease.release()
        secondLease.release()
    }

    private func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<1_000 {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for connection admission", sourceLocation: sourceLocation)
    }
}

private actor ChannelAdmissionProbe {
    private(set) var values: [Int] = []
    func admit(_ value: Int) { values.append(value) }
}

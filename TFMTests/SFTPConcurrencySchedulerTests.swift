// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain
import TermindRemoteInfrastructure
import Testing

@Suite
struct SFTPConcurrencySchedulerTests {
    @Test func finalPreferencesAffectQueuedWorkWithoutChangingGrantedPermits() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: .init(globalLimit: 1, perHostLimit: 1, strategy: .connectionsPreferred))
        let host = UUID()
        let first = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: .workspace(UUID()), byteCount: 80_000_000)
        let queued = Task {
            try await scheduler.acquire(
                anchorHostID: host, hostIDs: [host], source: .agentRun(UUID()), byteCount: 80_000_000)
        }
        try await eventually { await scheduler.queuedCount == 1 }
        await scheduler.updatePreferences(.init(globalLimit: 1, perHostLimit: 1, strategy: .channelsOnly))
        #expect(first.schedulingMode == .connectionsPreferred)
        await first.release()
        let next = try await queued.value
        #expect(next.schedulingMode == .channelsOnly)
        await next.release()
        await scheduler.updatePreferences(.init(strategy: .smart))
        let upgraded = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: .workspace(UUID()), byteCount: 80_000_000)
        #expect(upgraded.schedulingMode == .connectionsPreferred)
        await upgraded.release()
    }

    @Test func smartResolvesTheSixtyFourMBBoundaryAndUnknownSizeToSessions() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: SFTPPreferences(globalLimit: 3, perHostLimit: 3, strategy: .smart))
        let host = UUID()
        let source = SFTPWorkSource.workspace(UUID())

        let unknown = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: source, byteCount: nil)
        let boundary = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: source,
            byteCount: 64_000_000)
        let large = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: source,
            byteCount: 64_000_001)

        #expect(unknown.schedulingMode == .channelsOnly)
        #expect(boundary.schedulingMode == .channelsOnly)
        #expect(large.schedulingMode == .connectionsPreferred)
        await unknown.release()
        await boundary.release()
        await large.release()
    }

    @Test func sameHostRotatesFromWorkspaceToAgentRun() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: SFTPPreferences(globalLimit: 1, perHostLimit: 1, strategy: .channelsOnly))
        let host = UUID()
        let workspace = SFTPWorkSource.workspace(UUID())
        let agent = SFTPWorkSource.agentRun(UUID())
        let first = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: workspace, byteCount: 1)
        let recorder = GrantRecorder()
        let workspaceTask = queuedAcquire(
            scheduler: scheduler, host: host, source: workspace, label: "workspace", recorder: recorder)
        try await eventually { await scheduler.queuedCount == 1 }
        let agentTask = queuedAcquire(
            scheduler: scheduler, host: host, source: agent, label: "agent", recorder: recorder)
        try await eventually { await scheduler.queuedCount == 2 }

        await first.release()
        try await eventually { await recorder.values.count == 1 }
        let grants = await recorder.values
        #expect(grants == ["agent"])

        let winner = grants.first == "agent" ? agentTask : workspaceTask
        let loser = grants.first == "agent" ? workspaceTask : agentTask
        let winnerPermit = await winner.value
        await winnerPermit?.release()
        loser.cancel()
        _ = await loser.value
    }

    @Test func hostsRotateBeforeSources() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: SFTPPreferences(globalLimit: 1, perHostLimit: 1, strategy: .channelsOnly))
        let firstHost = UUID()
        let secondHost = UUID()
        let source = SFTPWorkSource.workspace(UUID())
        let first = try await scheduler.acquire(
            anchorHostID: firstHost, hostIDs: [firstHost], source: source, byteCount: 1)
        let recorder = GrantRecorder()
        let sameHostTask = queuedAcquire(
            scheduler: scheduler, host: firstHost, source: source, label: "first", recorder: recorder)
        try await eventually { await scheduler.queuedCount == 1 }
        let otherHostTask = queuedAcquire(
            scheduler: scheduler, host: secondHost, source: source, label: "second", recorder: recorder)
        try await eventually { await scheduler.queuedCount == 2 }

        await first.release()
        try await eventually { await recorder.values.count == 1 }
        let grants = await recorder.values
        #expect(grants == ["second"])

        let winner = grants.first == "second" ? otherHostTask : sameHostTask
        let loser = grants.first == "second" ? sameHostTask : otherHostTask
        let winnerPermit = await winner.value
        await winnerPermit?.release()
        loser.cancel()
        _ = await loser.value
    }

    @Test func crossHostCopyUsesOneGlobalSlotAndOneSlotOnEachHost() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: SFTPPreferences(globalLimit: 2, perHostLimit: 1, strategy: .channelsOnly))
        let sourceHost = UUID()
        let destinationHost = UUID()
        let unrelatedHost = UUID()
        let copy = try await scheduler.acquire(
            anchorHostID: destinationHost,
            hostIDs: [sourceHost, destinationHost],
            source: .workspace(UUID()),
            byteCount: 1)
        let unrelated = try await scheduler.acquire(
            anchorHostID: unrelatedHost,
            hostIDs: [unrelatedHost],
            source: .workspace(UUID()),
            byteCount: 1)

        #expect(await scheduler.activeCount == 2)
        #expect(await scheduler.activeCount(for: sourceHost) == 1)
        #expect(await scheduler.activeCount(for: destinationHost) == 1)
        #expect(await scheduler.activeCount(for: unrelatedHost) == 1)
        await copy.release()
        await unrelated.release()
    }

    @Test func fiveSameHostSlotsSplitThreeTwoAcrossWorkspaces() async throws {
        let scheduler = SFTPConcurrencyScheduler(
            preferences: SFTPPreferences(globalLimit: 1, perHostLimit: 5, strategy: .channelsOnly))
        let host = UUID()
        let blocker = try await scheduler.acquire(
            anchorHostID: host, hostIDs: [host], source: .batch(UUID()), byteCount: 1)
        let recorder = GrantRecorder()
        let first = SFTPWorkSource.workspace(UUID())
        let second = SFTPWorkSource.workspace(UUID())
        var tasks: [Task<SFTPConcurrencyPermit?, Never>] = []
        for _ in 0..<4 {
            tasks.append(
                queuedAcquire(
                    scheduler: scheduler, host: host, source: first,
                    label: "first", recorder: recorder))
            tasks.append(
                queuedAcquire(
                    scheduler: scheduler, host: host, source: second,
                    label: "second", recorder: recorder))
        }
        try await eventually { await scheduler.queuedCount == 8 }
        await scheduler.updatePreferences(
            SFTPPreferences(globalLimit: 5, perHostLimit: 5, strategy: .channelsOnly))
        await blocker.release()
        try await eventually { await recorder.values.count == 5 }

        let grants = await recorder.values
        #expect(grants.filter { $0 == "first" }.count == 3)
        #expect(grants.filter { $0 == "second" }.count == 2)

        for task in tasks { task.cancel() }
        for task in tasks {
            let permit = await task.value
            await permit?.release()
        }
    }

    private func queuedAcquire(
        scheduler: SFTPConcurrencyScheduler,
        host: UUID,
        source: SFTPWorkSource,
        label: String,
        recorder: GrantRecorder
    ) -> Task<SFTPConcurrencyPermit?, Never> {
        Task {
            do {
                let permit = try await scheduler.acquire(
                    anchorHostID: host, hostIDs: [host], source: source, byteCount: 1)
                await recorder.append(label)
                return permit
            } catch {
                return nil
            }
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition())
    }
}

private actor GrantRecorder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

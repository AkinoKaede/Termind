// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import Testing

@testable import TermindRemoteInfrastructure

@Suite
@MainActor
struct SFTPChannelLifetimeTests {
    @Test func siblingAndPendingDeinitCloseRetainTheConnectionOwner() async throws {
        let gate = CloseGate()
        var owner: LifetimeOwner? = LifetimeOwner()
        weak let releasedOwner = owner
        var driver: SFTPChannelDriver? = SFTPChannelDriver(
            identity: UUID(), retaining: owner,
            open: { UUID() },
            close: { _ in await gate.close() },
            perform: { _, _ in throw SFTPError.notConnected })
        var primary: (any SFTPChannelProtocol)? = try await SFTPChannel.open(using: driver!, charset: .utf8)
        var sibling: (any SFTPChannelProtocol)? = try await primary!.openSiblingChannel()
        driver = nil
        owner = nil
        primary = nil
        try await waitUntil { await gate.pendingCount == 1 }
        withExtendedLifetime(sibling) { #expect(releasedOwner != nil) }
        await gate.releasePending()
        sibling = nil
        try await waitUntil { await gate.pendingCount == 1 }
        #expect(releasedOwner != nil)
        await gate.releasePending()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while releasedOwner != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(releasedOwner == nil)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private final class LifetimeOwner: Sendable {}

    private actor CloseGate {
        var pending: [CheckedContinuation<Void, Never>] = []
        var pendingCount: Int { pending.count }

        func close() async {
            await withCheckedContinuation { pending.append($0) }
        }

        func releasePending() {
            let old = pending
            pending.removeAll()
            for continuation in old { continuation.resume() }
        }
    }
}

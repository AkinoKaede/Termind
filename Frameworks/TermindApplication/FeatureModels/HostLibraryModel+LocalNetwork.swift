// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

import struct TermindDomain.Host

public nonisolated enum HostWakeOutcome: Equatable, Sendable {
    case configurationRequired
    case sent
    case failed
}

extension HostLibraryModel {
    /// Lock checks precede configuration and packet transmission.
    public func requestWake(_ proposed: Host) async throws -> HostWakeOutcome {
        let wasSaved = host(proposed.id) != nil
        do {
            try hostAccess.requireAccess(to: proposed.id, in: hosts)
        } catch HostAccessError.verifyingEntitlement {
            await resolveInitialHostEntitlement?()
        }
        try Task.checkCancellation()
        guard !wasSaved || host(proposed.id) != nil else { throw CancellationError() }
        try hostAccess.requireAccess(to: proposed.id, in: hosts)
        let host = host(proposed.id) ?? proposed
        guard host.wakeOnLAN.address != nil else { return .configurationRequired }
        do {
            guard let wakeOnLAN else { throw WakeOnLANError.noLocalNetwork }
            try wakeOnLAN.wake(host.wakeOnLAN)
            return .sent
        } catch {
            return .failed
        }
    }
}

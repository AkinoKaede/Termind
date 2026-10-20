// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Presentation combines independently replicated categories without pretending
/// that one successful category means the whole account is up to date. Callers
/// exclude unselected categories; account confirmation/errors take precedence.
public nonisolated enum CloudSyncStatusSummary {
    public static func make(_ statuses: [VaultSyncStatus], isActive: Bool) -> VaultSyncStatus {
        guard isActive else { return .paused }
        guard !statuses.isEmpty else { return .checkingAccount }
        if statuses.contains(.accountChangeConfirmationRequired) { return .accountChangeConfirmationRequired }
        for status in statuses { if case .failed = status { return status } }
        if statuses.contains(.signInRequired) { return .signInRequired }
        for status in statuses { if case .unavailable = status { return status } }
        var pending = 0
        var blocked = 0
        var requiresUpdate = false
        var syncing = false
        for status in statuses {
            switch status {
            case .partiallyBlocked(let count, let restricted, let update):
                pending += count
                blocked += restricted
                requiresUpdate = requiresUpdate || update
            case .syncing(let count):
                pending += count
                syncing = true
            default: break
            }
        }
        if blocked > 0 {
            return .partiallyBlocked(pendingCount: pending, blockedCount: blocked, requiresUpdate: requiresUpdate)
        }
        if statuses.contains(.checkingAccount) { return .checkingAccount }
        if syncing { return .syncing(pendingCount: pending) }
        if statuses.contains(.paused) { return .paused }
        let dates = statuses.compactMap { status -> Date? in
            if case .upToDate(let date) = status { return date }
            return nil
        }
        // The oldest successful read is the last point all selected categories had synced.
        return .upToDate(lastSuccessfulSync: dates.count == statuses.count ? dates.min() : nil)
    }
}

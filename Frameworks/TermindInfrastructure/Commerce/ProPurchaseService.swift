// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import TermindDomain

@MainActor
protocol ProPurchaseService: AnyObject {
    var updates: AsyncStream<EntitlementStatus> { get }
    func currentStatus() async throws -> EntitlementStatus
}

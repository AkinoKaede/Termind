// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

nonisolated struct MCPServerSession: Sendable {
    var id: String
    var runID: UUID
    var secretBroker: SecretBroker
    var protocolVersion: String
    var clientName: String
    var isModern = false
    var initialized = false
    var isLegacy: Bool
    var legacyContinuation: AsyncStream<Data>.Continuation?
    var lastUsedAt: ContinuousClock.Instant = .now
}

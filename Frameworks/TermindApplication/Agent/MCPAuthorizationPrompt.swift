// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Ephemeral interaction only. The browser URL and callback never enter the transcript or persistence.
public nonisolated struct MCPAuthorizationPrompt: Identifiable, Sendable {
    public var id: UUID { request.id }
    public let request: MCPAuthorizationRequest
    public let createdAt: Date

    public init(request: MCPAuthorizationRequest, createdAt: Date = .now) {
        self.request = request
        self.createdAt = createdAt
    }
}

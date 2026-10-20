// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation
import SwiftData

/// Additive replay backing; historical message schemas remain frozen.
@Model
public final class PersistentAgentMessageReplay {
    @Attribute(.unique) public var messageID: UUID = UUID()
    public var contextData = Data()
    public var modelText: String?

    public init(_ message: AgentTranscriptMessage) {
        messageID = message.id
        contextData = message.contextSnapshot.map(AgentPersistenceRedactor.encoded) ?? Data()
        modelText = message.modelText.map {
            message.role == .tool
                ? AgentPersistenceRedactor.toolResultText($0, toolName: message.toolName)
                : AgentPersistenceRedactor.visibleText($0)
        }
    }

    public var contextSnapshot: AgentTurnContextSnapshot? {
        try? JSONDecoder().decode(AgentTurnContextSnapshot.self, from: contextData)
    }
}

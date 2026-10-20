// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

public nonisolated enum AgentPersistenceRedactor {
    private static let maximumVisibleCharacters = 262_144

    public static func visibleText(_ text: String) -> String {
        AgentSensitiveDataRedactor.visibleText(text, maximumCharacters: maximumVisibleCharacters)
    }

    public static func redactedJSON(_ value: AgentJSONValue) -> AgentJSONValue {
        AgentSensitiveDataRedactor.redactedJSON(value)
    }

    static func toolResultText(_ text: String, toolName: String?) -> String {
        let text = AgentSecretLifecycle.persistedResultText(toolName: toolName, original: text)
        // Secret lifecycle policy runs first; structural redaction must not retain handles.
        return AgentSensitiveDataRedactor.toolResultText(text)
    }

    static func restoredToolResultText(_ text: String, fallbacks: [String?]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.hasPrefix(AgentToolResult.untrustedDataOpeningMarker)
                || trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
            AgentToolResult.decodeStructuredPayload(text) == nil
        else { return text }
        // Earlier writers could corrupt JSON while leaving the frozen model
        // projection intact. Recover only from valid structured data, never guess.
        return fallbacks.compactMap { $0 }.first { AgentToolResult.decodeStructuredPayload($0) != nil } ?? text
    }

    public static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

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
        guard let value = decodedToolResult(text) else {
            return AgentSensitiveDataRedactor.visibleText(text)
        }
        // Tool/runtime policies own truncation. Cutting a serialized envelope or
        // redacting its escape sequences would destroy the retained presentation.
        let payload = redactedJSON(value).encodedString
        return text.hasPrefix(AgentToolResult.untrustedDataOpeningMarker)
            ? AgentToolResult.untrustedDataOpeningMarker + payload + AgentToolResult.untrustedDataClosingMarker
            : payload
    }

    static func restoredToolResultText(_ text: String, fallbacks: [String?]) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            trimmed.hasPrefix(AgentToolResult.untrustedDataOpeningMarker)
                || trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
            decodedToolResult(text) == nil
        else { return text }
        // Earlier writers could corrupt JSON while leaving the frozen model
        // projection intact. Recover only from valid structured data, never guess.
        return fallbacks.compactMap { $0 }.first { decodedToolResult($0) != nil } ?? text
    }

    private static func decodedToolResult(_ text: String) -> AgentJSONValue? {
        let result = AgentToolResult(callID: "", content: text, metadata: ["untrusted": .bool(true)])
        return try? AgentJSONValue.decode(Data((result.untrustedPayload ?? text).utf8))
    }

    public static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

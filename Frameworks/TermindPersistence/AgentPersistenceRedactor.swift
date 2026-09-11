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

    public static func encoded<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

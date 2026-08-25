import Foundation

/// One redaction policy for model review, live approval/tool cards, and durable
/// history. Fetch headers use `{name,value}`, so key-only redaction is not
/// enough: the header name determines whether its sibling value is sensitive.
nonisolated enum AgentSensitiveDataRedactor {
    private static let sensitiveKeys = [
        "password", "passwd", "secret", "token", "authorization", "cookie", "api_key",
        "api-key", "apikey",
    ]

    static func visibleText(_ text: String, maximumCharacters: Int? = nil) -> String {
        var output = maximumCharacters.map { String(text.prefix($0)) } ?? text
        for key in sensitiveKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = "(?i)(\\\"?\(escaped)\\\"?\\s*[:=]\\s*)(\\\"[^\\\"]*\\\"|[^\\s,}]+)"
            output = output.replacingOccurrences(
                of: pattern, with: "$1\"[REDACTED]\"", options: .regularExpression
            )
        }
        return output
    }

    static func redactedJSON(_ value: AgentJSONValue) -> AgentJSONValue {
        switch value {
        case .object(let object):
            let headerIsSensitive = object["name"]?.stringValue.map(isSensitiveHeader) == true
            return .object(
                object.reduce(into: [:]) { output, pair in
                    if isSensitiveKey(pair.key) || headerIsSensitive && pair.key == "value" {
                        output[pair.key] = .string("[REDACTED]")
                    } else {
                        output[pair.key] = redactedJSON(pair.value)
                    }
                })
        case .array(let array): return .array(array.map(redactedJSON))
        case .string(let string): return .string(visibleText(string))
        default: return value
        }
    }

    static func isSensitiveHeader(_ name: String) -> Bool {
        isSensitiveKey(name.replacingOccurrences(of: "-", with: "_"))
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return sensitiveKeys.contains { lowered.contains($0) }
    }
}

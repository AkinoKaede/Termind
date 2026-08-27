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
                        // Provider strict-mode arguments spell an omitted
                        // optional field as `null`. Turning that absence into a
                        // string creates a value that never existed — especially
                        // dangerous for one-shot handles, because a later turn
                        // can copy "[REDACTED]" back into the tool as if it were
                        // a credential. Preserve absence (and the harmless empty
                        // string); redact only a value that actually carries
                        // something.
                        switch pair.value {
                        case .null, .string(""):
                            output[pair.key] = pair.value
                        default:
                            output[pair.key] = .string("[REDACTED]")
                        }
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

/// Removes capabilities whose lifetime ended with the run that issued them.
///
/// Secret handles are deliberately process-local, run-bound, and single-use.
/// A transcript is durable and replayed, so retaining a handle there would
/// invite a future model turn to reuse a value that cannot possibly work. The
/// live run is not passed through this type: it still needs the real result for
/// the immediate `request_user_secret` -> `ssh_exec` handoff.
nonisolated enum AgentSecretLifecycle {
    static let expiredResultContent =
        AgentToolResult.untrustedDataOpeningMarker
        + AgentJSONValue.object([
            "handle_status": .string("expired"),
            "single_use": .bool(true),
        ]).encodedString
        + AgentToolResult.untrustedDataClosingMarker

    static func sanitizeHistoricalMessages(
        _ messages: [AgentTranscriptMessage]
    ) -> [AgentTranscriptMessage] {
        let secretRequestCallIDs = Set(messages.flatMap(\.toolCalls).compactMap { call in
            call.name == "request_user_secret" ? call.id : nil
        })

        return messages.map { original in
            var message = original
            if message.role == .assistant {
                message.toolCalls = message.toolCalls.map { originalCall in
                    guard originalCall.name == "ssh_exec",
                        var arguments = originalCall.arguments.objectValue
                    else { return originalCall }
                    arguments.removeValue(forKey: "secret_handle")
                    var call = originalCall
                    call.arguments = .object(arguments)
                    return call
                }
            }
            if message.role == .tool,
                message.toolName == "request_user_secret"
                    || message.toolCallID.map(secretRequestCallIDs.contains) == true
            {
                message.text = expiredResultContent
            }
            return message
        }
    }

    static func persistedResultText(toolName: String?, original: String) -> String {
        toolName == "request_user_secret" ? expiredResultContent : original
    }
}

import Foundation

/// Compact disclosure titles derived from diagnostics, without changing the full error detail.
public enum AssistantFailurePresentation {
    public static func summary(for reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        var message = trimmed.components(separatedBy: .newlines).first ?? ""
        if let start = trimmed.firstIndex(of: "{") {
            let prefix = String(trimmed[..<start]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !prefix.isEmpty { message = prefix }
            if let end = trimmed.lastIndex(of: "}"), start <= end,
                trimmed.utf8.count <= 65_536,
                let object = try? JSONSerialization.jsonObject(with: Data(trimmed[start...end].utf8))
                    as? [String: Any]
            {
                let error = object["error"] as? [String: Any]
                let candidates = [error?["message"], object["message"], object["error"]]
                if let detail = candidates.compactMap({ $0 as? String })
                    .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                {
                    message = detail
                }
            }
        }
        let singleLine = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !singleLine.isEmpty else { return String(localized: AppStrings.Assistant.agentError) }
        return singleLine.count > 160 ? String(singleLine.prefix(159)) + "\u{2026}" : singleLine
    }
}

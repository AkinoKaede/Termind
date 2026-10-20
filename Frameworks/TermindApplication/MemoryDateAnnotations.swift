// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import Foundation

/// Date comments are an editing/export representation, never part of memory content.
public nonisolated enum MemoryDateAnnotations {
    public static func text(
        for target: AgentMemoryTarget, in state: AgentMemoryState, references: [UUID: Date]
    ) -> String {
        state.entries.filter { $0.target == target }.map { entry in
            let created = date(entry.createdAt)
            let last = date(references[entry.id] ?? entry.createdAt)
            return "\(entry.content) <!-- created=\(created), last=\(last) -->"
        }.joined(separator: "\n§\n")
    }

    public static func document(_ state: AgentMemoryState, references: [UUID: Date]) -> String {
        AgentMemoryTarget.allCases.map { target in
            "\(target == .memory ? "MEMORY" : "USER PROFILE")\n\(text(for: target, in: state, references: references))"
        }.joined(separator: "\n\n")
    }

    public static func draftUsage(_ text: String) -> (entries: Int, characters: Int) {
        let entries = text.components(separatedBy: "\n§\n").map { edited in
            (try? content(from: edited)) ?? edited.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        return (entries.count, entries.joined(separator: "\n§\n").unicodeScalars.count)
    }

    public static func content(from editedEntry: String) throws -> String {
        let trimmed = editedEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        let content: String
        if let range = trimmed.range(
            of: #"\s*<!--\s*created\s*=[^>]*-->\s*$"#, options: .regularExpression)
        {
            content = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            content = trimmed
        }
        if content.range(
            of: #"(?:created|last)\s*=|<!--\s*(?:creat\w*|last\w*)\b"#,
            options: [.regularExpression, .caseInsensitive])
            != nil
        {
            throw AgentToolError.invalidArguments("Remove the damaged memory date comment before saving.")
        }
        return content
    }

    private static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: value)
    }
}

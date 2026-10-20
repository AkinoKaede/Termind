// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation

public nonisolated enum TagFieldPolicy {
    /// A single row type keeps selection, activation, and submission on the same ordered list.
    public enum Row: Hashable, Sendable {
        case existing(String)
        case create(String)
    }

    public static func rows(tags: [String], suggestions: [String], query: String) -> [Row] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        let taken = Set(tags.map { $0.lowercased() })
        let matches =
            suggestions
            .filter { !taken.contains($0.lowercased()) }
            .filter { trimmedQuery.isEmpty || $0.localizedCaseInsensitiveContains(trimmedQuery) }

        guard !trimmedQuery.isEmpty else { return matches.map(Row.existing) }
        let spokenFor = taken.union(suggestions.map { $0.lowercased() })
        guard !spokenFor.contains(trimmedQuery.lowercased()) else { return matches.map(Row.existing) }
        return matches.map(Row.existing) + [.create(trimmedQuery)]
    }

    public static func submission(query: String, suggestions: [String]) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return suggestions.first { $0.caseInsensitiveCompare(trimmed) == .orderedSame } ?? trimmed
    }

    public static func adding(_ tag: String, to tags: [String]) -> [String] {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
            !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        else { return tags }
        return tags + [trimmed]
    }

    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0 != tag }
    }
}

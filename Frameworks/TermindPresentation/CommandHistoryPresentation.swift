// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Foundation
import TermindDomain

public nonisolated enum CommandHistoryPresentation {
    public static func title(for entry: CommandHistoryEntry) -> String {
        guard let lineBreak = entry.command.rangeOfCharacter(from: .newlines) else {
            return entry.command
        }
        return String(entry.command[..<lineBreak.lowerBound]) + "…"
    }

    public static func subtitle(for entry: CommandHistoryEntry, locale: Locale) -> String {
        var parts: [String] = []
        if let date = entry.executedAt {
            parts.append(date.formatted(.relative(presentation: .numeric).locale(locale)))
        }
        if let duration = entry.duration, let formatted = formattedDuration(duration) {
            parts.append(formatted)
        }
        return parts.joined(separator: " · ")
    }

    private static func formattedDuration(_ duration: TimeInterval) -> String? {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        formatter.allowedUnits = duration < 60 ? [.second] : [.hour, .minute, .second]
        return formatter.string(from: max(0, duration))
    }
}

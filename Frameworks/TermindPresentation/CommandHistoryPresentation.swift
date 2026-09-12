import Foundation
import TermindDomain

public nonisolated enum CommandHistoryPresentation {
    public static func subtitle(for entry: CommandHistoryEntry, locale: Locale) -> String {
        var parts = [
            entry.executedAt.formatted(
                .relative(presentation: .numeric).locale(locale)
            )
        ]
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

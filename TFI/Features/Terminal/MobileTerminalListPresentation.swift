import SwiftUI
import TermindDomain
import UIKit

struct MobileTerminalRiskIndicator: View {
    let assessment: RiskAssessment

    var body: some View {
        Image(systemName: assessment.risk.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color(uiColor: Self.color(for: assessment.risk)))
            .frame(width: 24, height: 24)
            .contentShape(.rect)
            .accessibilityElement()
            .accessibilityLabel(assessment.risk.label)
            .accessibilityValue(assessment.reasons.first ?? "")
            .accessibilityIdentifier(Self.accessibilityIdentifier(for: assessment.risk))
    }

    static func color(for risk: CommandRisk) -> UIColor {
        switch risk {
        case .safe: .systemGreen
        case .caution: .systemOrange
        case .destructive: .systemRed
        }
    }

    static func accessibilityIdentifier(for risk: CommandRisk) -> String {
        switch risk {
        case .safe: "TerminalRisk.safe"
        case .caution: "TerminalRisk.caution"
        case .destructive: "TerminalRisk.destructive"
        }
    }
}

enum MobileTerminalHistoryPresentation {
    static func subtitle(for entry: CommandHistoryEntry, locale: Locale) -> String {
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

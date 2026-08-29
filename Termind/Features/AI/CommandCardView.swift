import SwiftUI

extension CommandRisk {
    var tint: Color {
        switch self {
        case .safe: TermindColor.success
        case .caution: TermindColor.warning
        case .destructive: TermindColor.danger
        }
    }
}
/// The risk label shown on every proposed command.
///
/// The rating comes from `CommandRiskClassifier` running locally, never from the
/// model's own description of what it suggested.
struct RiskBadge: View {
    let assessment: RiskAssessment
    var compact = false

    var body: some View {
        Label {
            if !compact { Text(assessment.risk.label) }
        } icon: {
            Image(systemName: assessment.risk.symbol)
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(assessment.risk.tint)
        .padding(.horizontal, compact ? 0 : Metrics.Space.s)
        .padding(.vertical, 2)
        .background {
            if !compact {
                Capsule().fill(assessment.risk.tint.opacity(0.12))
            }
        }
        .help(Text(assessment.reasons.first ?? assessment.risk.label))
    }
}

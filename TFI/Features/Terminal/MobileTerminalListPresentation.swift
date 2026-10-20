// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

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

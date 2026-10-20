// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindDomain
import TermindPresentation

struct MobileCompactSnippetCardContent: View {
    let snippet: Snippet

    private var risk: CommandRisk { CommandRiskClassifier.assess(snippet.body).risk }

    var riskTitle: LocalizedStringResource {
        switch risk {
        case .safe: AppStrings.Snippets.readOnlyRisk
        case .caution: AppStrings.Snippets.cautionRisk
        case .destructive: AppStrings.Snippets.destructiveRisk
        }
    }

    private var tint: Color {
        switch risk {
        case .safe: .green
        case .caution: .orange
        case .destructive: .red
        }
    }

    var body: some View {
        MobileCompactCardContent(title: snippet.title, status: Text(riskTitle)) {
            MobileCardIcon(symbol: "curlybraces", tint: snippet.colorTag.color ?? .accentColor)
                .overlay(alignment: .bottomTrailing) {
                    MobileCompactCardBadge(symbol: risk.symbol, tint: tint)
                }
        }
    }
}

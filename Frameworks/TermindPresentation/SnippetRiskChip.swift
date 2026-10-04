import SwiftUI
import TermindApplication
import TermindDomain

public struct SnippetRiskChip: View {
    @Environment(\.locale) private var locale
    private let assessment: RiskAssessment

    public init(assessment: RiskAssessment) {
        self.assessment = assessment
    }

    public var body: some View {
        LibraryCardChip(
            text: AppLocalization.resolve(title, locale: locale), symbol: assessment.risk.symbol, tint: tint)
    }

    private var title: LocalizedStringResource {
        switch assessment.risk {
        case .safe: AppStrings.Snippets.readOnlyRisk
        case .caution: AppStrings.Snippets.cautionRisk
        case .destructive: AppStrings.Snippets.destructiveRisk
        }
    }

    private var tint: Color {
        switch assessment.risk {
        case .safe: .green
        case .caution: .orange
        case .destructive: .red
        }
    }
}

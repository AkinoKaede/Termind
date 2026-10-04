import SwiftUI
import TermindApplication
import TermindDomain

/// The shared content of library cards; each platform owns the surrounding surface and interactions.
public struct SnippetCardContent: View {
    @Environment(\.locale) private var locale

    private let snippet: Snippet
    private let validTargetCount: Int
    private let packagePath: String?
    private let modifiedAt: Date

    public init(snippet: Snippet, validTargetCount: Int, packagePath: String? = nil, modifiedAt: Date) {
        self.snippet = snippet
        self.validTargetCount = validTargetCount
        self.packagePath = packagePath
        self.modifiedAt = modifiedAt
    }

    #if os(macOS)
        private let rowSpacing: CGFloat = 6
        private let iconSpacing: CGFloat = 8
        private let titleSpacing: CGFloat = 1
    #else
        private let rowSpacing: CGFloat = 12
        private let iconSpacing: CGFloat = 12
        private let titleSpacing: CGFloat = 4
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack(alignment: .top, spacing: iconSpacing) {
                LibraryCardIcon(symbol: "curlybraces", tint: snippet.colorTag.color ?? .accentColor)
                VStack(alignment: .leading, spacing: titleSpacing) {
                    Text(snippet.title).font(.headline).lineLimit(1)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) { metadataChips }
                        VStack(alignment: .leading, spacing: 6) { metadataChips }
                    }
                }
            }
            HStack(spacing: 6) {
                if let packagePath {
                    Label(packagePath, systemImage: "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(modifiedAt.formatted(.relative(presentation: .numeric).locale(locale)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    @ViewBuilder private var metadataChips: some View {
        LibraryCardChip(
            text: AppLocalization.resolve(AppStrings.Snippets.targetSummary(count: validTargetCount), locale: locale),
            symbol: "server.rack")
        SnippetRiskChip(assessment: CommandRiskClassifier.assess(snippet.body))
    }
}

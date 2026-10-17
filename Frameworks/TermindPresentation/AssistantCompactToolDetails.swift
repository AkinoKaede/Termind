import AgentKit
import SwiftUI

/// A compact tool body. Expansion belongs to the transcript, never to a recycled row.
public struct AssistantCompactToolDetails: View {
    private let preview: AgentToolDetailPreview
    private let isError: Bool
    private let truncateMarker: String?
    @Binding private var expanded: Bool

    public init(
        detail: AgentToolDetail, isError: Bool, expanded: Binding<Bool>,
        strategy: AgentTruncateStrategy = .head, preservesFirstText: Bool = false,
        truncateMarker: String? = nil
    ) {
        preview = AgentToolDetailPreview(detail, strategy: strategy, preservesFirstText: preservesFirstText)
        self.isError = isError
        self.truncateMarker = truncateMarker
        _expanded = expanded
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantToolDetails(
                items: expanded ? preview.fullItems : preview.items, isError: isError
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let truncateMarker {
                Text(truncateMarker)
                    .font(.caption2).foregroundStyle(.orange)
            }
            if expanded || preview.isShortened {
                Button(
                    expanded ? AppStrings.Assistant.showLess.swiftUIKey : AppStrings.Assistant.showMore.swiftUIKey
                ) { expanded.toggle() }
                .accessibilityIdentifier("AssistantTool.More")
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
        }
        .accessibilityIdentifier("AssistantTool.CompactDetails")
    }
}

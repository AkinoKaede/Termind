import AgentKit
import SwiftUI

/// The compact knowledge-tool body. Expansion belongs to the transcript, never to a recycled row.
public struct AssistantCompactToolDetails: View {
    private let preview: AgentToolDetailPreview
    private let isError: Bool
    private let copy: (String) -> Void
    @Binding private var expanded: Bool
    @ScaledMetric(relativeTo: .caption) private var previewHeight: CGFloat = 180
    @State private var contentHeight: CGFloat = 0

    public init(detail: AgentToolDetail, isError: Bool, expanded: Binding<Bool>, copy: @escaping (String) -> Void) {
        preview = AgentToolDetailPreview(detail)
        self.isError = isError
        _expanded = expanded
        self.copy = copy
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistantToolDetails(items: expanded ? preview.fullItems : preview.items, isError: isError, copy: copy)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
                .frame(maxHeight: expanded ? nil : previewHeight, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
            if expanded || preview.isShortened || contentHeight > previewHeight {
                HStack(spacing: 16) {
                    Button(
                        expanded ? AppStrings.Assistant.showLess.swiftUIKey : AppStrings.Assistant.showMore.swiftUIKey
                    ) { expanded.toggle() }
                    .accessibilityIdentifier("AssistantTool.More")
                    Button(AppStrings.Common.copy.swiftUIKey, systemImage: "doc.on.doc") { copy(preview.fullText) }
                        .accessibilityIdentifier("AssistantTool.Copy")
                }
                .font(.caption)
                .frame(minHeight: 44)
            }
        }
        .accessibilityIdentifier("AssistantTool.CompactDetails")
    }
}

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import AgentKit
import SwiftUI

private struct AssistantToolNavigationKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AgentToolDetail.NavigationReference) -> Void)? = nil
}

extension EnvironmentValues {
    /// App-owned navigation for trusted references emitted by built-in tool presenters.
    public var assistantToolNavigation: (@MainActor (AgentToolDetail.NavigationReference) -> Void)?
    {
        get { self[AssistantToolNavigationKey.self] }
        set { self[AssistantToolNavigationKey.self] = newValue }
    }
}

/// Renders retained items verbatim; transcript folding belongs to AssistantCompactToolDetails.
public struct AssistantToolDetails: View {
    private let items: [AgentToolDetail.Item]
    private let isError: Bool
    private let textColor: Color
    private let resourceStyle: Bool
    @Environment(\.assistantToolNavigation) private var navigate
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(
        items: [AgentToolDetail.Item],
        isError: Bool = false,
        textColor: Color = .secondary,
        resourceStyle: Bool = false
    ) {
        self.items = items
        self.isError = isError
        self.textColor = textColor
        self.resourceStyle = resourceStyle
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in item(items[index]) }
        }.textSelection(.enabled)
    }

    @ViewBuilder private func item(_ value: AgentToolDetail.Item) -> some View {
        switch value {
        case .field(let field):
            if resourceStyle, field.navigation == nil, field.url == nil, !field.value.isEmpty,
                field.value.count <= 48, !field.value.contains("\n"), !dynamicTypeSize.isAccessibilitySize
            {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(field.label).foregroundStyle(.secondary).fixedSize()
                        Spacer(minLength: 8)
                        Text(field.value).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label).foregroundStyle(.secondary)
                        Text(field.value)
                    }
                }
                .font(.caption)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(field.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if !field.value.isEmpty {
                        if let navigation = field.navigation, let navigate {
                            Button(field.value) { navigate(navigation) }
                                .font(field.isMonospaced ? .caption.monospaced() : .caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.tint)
                        } else if let url = linkURL(field.url) {
                            Link(field.value, destination: url).font(.caption)
                        } else {
                            Text(field.value).font(field.isMonospaced ? .caption.monospaced() : .caption)
                                .foregroundStyle(isError ? Color.red : .primary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .message(let text, let tint): Text(text).foregroundStyle(color(tint))
        case .text(let block):
            if let title = block.title { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            ScrollView(resourceStyle ? [.horizontal, .vertical] : .horizontal) {
                Text(block.text)
                    .font(block.style == .monospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(isError ? Color.red : textColor)
            }
            .frame(maxHeight: resourceStyle ? 200 : nil)
        case .list(let list):
            if let title = list.title { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            if list.rows.isEmpty, let empty = list.emptyMessage { Text(empty).foregroundStyle(.secondary) }
            rows(list.rows)
        case .groupedList(let list):
            Text(list.summary).font(.caption)
            ForEach(list.sections.indices, id: \.self) { index in
                Text(list.sections[index].title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                rows(list.sections[index].rows)
            }
        }
    }

    private func rows(_ rows: [AgentToolDetail.ListRow]) -> some View {
        ForEach(rows.indices, id: \.self) { index in
            let row = rows[index]
            HStack(alignment: .top) {
                if let symbol = row.symbol { Image(systemName: symbol).foregroundStyle(color(row.tint)) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                    if let subtitle = row.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    if let detail = row.detail { Text(detail).font(.caption.monospaced()) }
                    if !row.badges.isEmpty { Text(row.badges.joined(separator: " · ")).font(.caption) }
                    if let navigation = row.navigation, let navigate {
                        Button(AppStrings.Common.open.swiftUIKey) { navigate(navigation) }
                    } else if let url = linkURL(row.url) {
                        Link(AppStrings.Common.open.swiftUIKey, destination: url)
                    }
                }
            }
        }
    }

    private func linkURL(_ value: String?) -> URL? {
        guard let value else { return nil }
        return URL(string: value)
    }

    private func color(_ tint: AgentToolDetail.Tint) -> Color {
        switch tint {
        case .secondary: .secondary
        case .warning: .orange
        case .success: .green
        case .failure: .red
        }
    }
}

/// The shared body of the macOS and mobile approval cards.
/// Tool arguments remain fully visible; only the safety explanation is folded.
public struct AssistantApprovalDetails: View {
    @ScaledMetric(relativeTo: .caption) private var approvalHeight: CGFloat = 240
    private let detail: AgentToolDetail
    private let reasons: [String]
    private let resourceStyle: Bool
    @Binding private var showsSafetyDetails: Bool

    public init(
        detail: AgentToolDetail,
        reasons: [String],
        showsSafetyDetails: Binding<Bool>,
        resourceStyle: Bool = false
    ) {
        self.detail = detail
        self.reasons = reasons
        self.resourceStyle = resourceStyle
        _showsSafetyDetails = showsSafetyDetails
    }

    public var body: some View {
        AssistantApprovalDetailsLayout(maxHeight: detail.layout.boundsApprovalHeight ? approvalHeight : nil) {
            ViewThatFits(in: .vertical) {
                content.fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    content
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityIdentifier("AssistantApproval.Details")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistantToolDetails(items: detail.items, textColor: .primary, resourceStyle: resourceStyle)
            if !reasons.isEmpty {
                DisclosureGroup(isExpanded: $showsSafetyDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(reasons, id: \.self) { reason in
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    HStack(spacing: 6) {
                        Label("Safety details", systemImage: "exclamationmark.triangle")
                        Text(reasons.count, format: .number)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("AssistantApproval.SafetyDetails")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AssistantApprovalDetailsLayout: Layout {
    let maxHeight: CGFloat?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        // A flexible max-height frame fills its proposal even for a single row.
        // Measure the natural height first, then leave overflow to ViewThatFits.
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(
            width: natural.width,
            height: max(0, min(natural.height, maxHeight ?? .infinity, proposal.height ?? .infinity))
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

public nonisolated struct AgentApprovalPresentation: Equatable, Sendable {
    public let symbol: String
    public let title: String
    public let detail: AgentToolDetail

    public init(symbol: String, title: String, detail: AgentToolDetail) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

import AgentKit
import SwiftUI

public struct AssistantToolDetails: View {
    private let items: [AgentToolDetail.Item]
    private let isError: Bool
    private let copy: ((String) -> Void)?
    private let shortensText: Bool
    private let textColor: Color
    public init(
        items: [AgentToolDetail.Item],
        isError: Bool = false,
        shortensText: Bool = true,
        textColor: Color = .secondary,
        copy: ((String) -> Void)? = nil
    ) {
        self.items = items
        self.isError = isError
        self.shortensText = shortensText
        self.textColor = textColor
        self.copy = copy
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in item(items[index]) }
        }.textSelection(.enabled)
    }

    @ViewBuilder private func item(_ value: AgentToolDetail.Item) -> some View {
        switch value {
        case .field(let field):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(field.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                if let url = allowedURL(field.url) {
                    Link(field.value, destination: url).font(.caption)
                } else {
                    Text(field.value).font(field.isMonospaced ? .caption.monospaced() : .caption)
                        .foregroundStyle(isError ? Color.red : .primary)
                }
            }
        case .message(let text, let tint): Text(text).foregroundStyle(color(tint))
        case .text(let block):
            if let title = block.title { Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            let preview = shortensText ? AgentToolPresentation.preview(block.text) : nil
            ScrollView(.horizontal) {
                Text(preview?.displayed ?? block.text)
                    .font(block.style == .monospaced ? .caption.monospaced() : .caption)
                    .foregroundStyle(isError ? Color.red : textColor)
            }
            if let preview, preview.isShortened {
                HStack {
                    Text(AppStrings.Assistant.outputShortenedForDisplay).font(.caption2).foregroundStyle(.secondary)
                    if let copy {
                        Button(AppStrings.Common.copy.swiftUIKey, systemImage: "doc.on.doc") { copy(preview.full) }
                            .font(.caption).frame(minHeight: 44)
                    }
                }
            }
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
                    if let url = allowedURL(row.url) {
                        Link(AppStrings.Common.open.swiftUIKey, destination: url)
                    }
                }
            }
        }
    }

    private func allowedURL(_ value: String?) -> URL? {
        guard let value, TermindMarkdownParser.isAllowedLink(value) else { return nil }
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
    private let detail: AgentToolDetail
    private let reasons: [String]
    @Binding private var showsSafetyDetails: Bool

    public init(
        detail: AgentToolDetail,
        reasons: [String],
        showsSafetyDetails: Binding<Bool>
    ) {
        self.detail = detail
        self.reasons = reasons
        _showsSafetyDetails = showsSafetyDetails
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            AssistantToolDetails(items: detail.items, shortensText: false, textColor: .primary)
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
        .accessibilityIdentifier("AssistantApproval.Details")
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

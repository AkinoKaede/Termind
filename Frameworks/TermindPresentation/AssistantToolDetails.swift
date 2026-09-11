import AgentKit
import SwiftUI

public struct AssistantToolDetails: View {
    private let items: [AgentToolDetail.Item]
    public init(items: [AgentToolDetail.Item]) { self.items = items }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items.indices, id: \.self) { index in item(items[index]) }
        }.textSelection(.enabled)
    }

    @ViewBuilder private func item(_ value: AgentToolDetail.Item) -> some View {
        switch value {
        case .field(let field):
            LabeledContent(field.label) {
                Text(field.value).font(field.isMonospaced ? .caption.monospaced() : .caption)
            }
        case .message(let text, let tint): Text(text).foregroundStyle(color(tint))
        case .text(let block):
            if let title = block.title { Text(title).font(.headline) }
            ScrollView(.horizontal) {
                Text(block.text).font(block.style == .monospaced ? .callout.monospaced() : .callout)
            }
        case .list(let list):
            if let title = list.title { Text(title).font(.headline) }
            if list.rows.isEmpty, let empty = list.emptyMessage { Text(empty).foregroundStyle(.secondary) }
            rows(list.rows)
        case .groupedList(let list):
            Text(list.summary).font(.caption)
            ForEach(list.sections.indices, id: \.self) { index in
                Text(list.sections[index].title).font(.headline)
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
                    if let string = row.url, let url = URL(string: string),
                        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                    {
                        Link("Open", destination: url)
                    }
                }
            }
        }
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

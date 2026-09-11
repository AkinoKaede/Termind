import AppKit
import ListViewKit
import SwiftUI
import TermindApplication

/// The palette that opens when a draft starts with `/`.
///
/// Drawn in the composer's own rounded block, directly above it, and floating
/// over whatever else sits between the transcript and the composer — an approval
/// card, a question, the steering strip. It covers them rather than displacing
/// them, so opening it never reflows the conversation behind it.
///
/// Its height is its content's: the block shrinks as the filter narrows and the
/// whole thing disappears when nothing matches. The scroll cap only exists so a
/// future command list cannot grow past the window.
struct SlashCommandMenuView: View {
    let completion: ChatSlashCommandCompletion
    let selection: Int
    /// Advanced only by keyboard navigation. Hover still changes the highlight,
    /// but must not recenter a list underneath a stationary pointer.
    let scrollRequest: Int
    var surfaceStyle: AssistantInteractionSurfaceStyle = .standard
    var contextShare: Double?
    /// The value a row currently holds — the resolved effort beside
    /// `/reasoning`. Returning `nil` leaves the trailing column empty.
    var trailingText: (ChatSlashCommandCompletion.Row) -> String? = { _ in nil }
    var onHover: (Int) -> Void = { _ in }
    var onSelect: (ChatSlashCommandCompletion.Row) -> Void

    var body: some View {
        SlashCommandNativeList(items: listItems, scrollRequest: scrollRequest) { item in
            row(item.row, isSelected: item.isSelected)
                .onHover { inside in
                    if inside { onHover(item.index) }
                }
        }
        // Naturally sized until it would be taller than this. `basedOnSize` is
        // what stops a short list from rubber-banding when the pointer crosses
        // it while longer command and option lists remain scrollable.
        .frame(height: listHeight)
        .composerBlock(style: surfaceStyle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Commands"))
    }

    private var listItems: [SlashCommandListItem] {
        Array(completion.rows.enumerated()).map { index, row in
            SlashCommandListItem(index: index, row: row, isSelected: index == selection)
        }
    }

    private var listHeight: CGFloat {
        min(Metrics.Chat.slashMenuMaxHeight, CGFloat(completion.rows.count) * 34)
    }

    private func row(
        _ row: ChatSlashCommandCompletion.Row, isSelected: Bool
    ) -> some View {
        Button {
            onSelect(row)
        } label: {
            HStack(spacing: Metrics.Space.s) {
                icon(for: row)
                    .frame(width: Metrics.Sidebar.rowIcon)

                Text(title(of: row))
                    .font(.callout)
                    .lineLimit(1)

                Text(subtitle(of: row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Metrics.Space.s)

                if let trailing = trailingText(row) {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Metrics.Space.s)
            .padding(.vertical, Metrics.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear),
                in: .rect(cornerRadius: Metrics.Radius.medium)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func icon(for row: ChatSlashCommandCompletion.Row) -> some View {
        switch row {
        case .command(let command), .option(let command, _):
            icon(for: command)
        }
    }

    @ViewBuilder
    private func icon(for command: ChatSlashCommand) -> some View {
        switch command.icon {
        case .symbol(let name):
            Image(systemName: name).font(.caption)
        case .contextRing:
            ContextRing(share: contextShare ?? 0)
        }
    }

    private func title(of row: ChatSlashCommandCompletion.Row) -> String {
        switch row {
        case .command(let command): command.displayName
        case .option(_, let option): option.label
        }
    }

    private func subtitle(of row: ChatSlashCommandCompletion.Row) -> String {
        switch row {
        case .command(let command): command.summary
        case .option(_, let option): option.detail
        }
    }

}

nonisolated private struct SlashCommandListItem: Identifiable, Hashable, Sendable {
    let index: Int
    let row: ChatSlashCommandCompletion.Row
    let isSelected: Bool
    var id: ChatSlashCommandCompletion.Row.ID { row.id }
}

private struct SlashCommandNativeList: NSViewRepresentable {
    typealias NSViewType = ListView<SlashCommandListItem>
    typealias Renderer = @MainActor (SlashCommandListItem) -> AnyView

    let items: [SlashCommandListItem]
    let scrollRequest: Int
    let renderer: Renderer
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme

    init(
        items: [SlashCommandListItem],
        scrollRequest: Int,
        @ViewBuilder renderer: @escaping @MainActor (SlashCommandListItem) -> some View
    ) {
        self.items = items
        self.scrollRequest = scrollRequest
        self.renderer = { AnyView(renderer($0)) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSViewType { context.coordinator.makeListView() }
    func updateNSView(_ listView: NSViewType, context: Context) {
        context.coordinator.update(
            listView: listView, items: items, scrollRequest: scrollRequest,
            renderer: renderer, locale: locale, colorScheme: colorScheme
        )
    }

    @MainActor
    final class Coordinator {
        private let content = HostingListContent<SlashCommandListItem>()
        private var lastScrollRequest: Int?

        func makeListView() -> NSViewType {
            let listView = NSViewType()
            listView.rowAnimator = ListBouncyAnimator(style: .regular)
            listView.estimatedRowHeight = 34
            listView.rows {
                ListRow(HostingListRow.self)
                    .height { _, _ in 34 }
                    .configure { [weak self] row, item, _ in self?.configure(row, item: item) }
            }
            return listView
        }

        func update(
            listView: NSViewType, items: [SlashCommandListItem], scrollRequest: Int,
            renderer: @escaping Renderer, locale: Locale, colorScheme: ColorScheme
        ) {
            let identitiesChanged = content.update(
                listView, items: items, renderer: renderer, locale: locale,
                colorScheme: colorScheme, animated: true
            )

            if identitiesChanged || lastScrollRequest != scrollRequest {
                lastScrollRequest = scrollRequest
                if let selected = items.first(where: \.isSelected) {
                    listView.scrollToRow(with: selected.id, at: .nearest, animated: false)
                }
            }
        }

        private func configure(_ row: HostingListRow, item: SlashCommandListItem) {
            content.configure(row, item: item)
        }
    }
}

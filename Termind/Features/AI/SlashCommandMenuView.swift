import SwiftUI

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
    /// Drawn in place of a symbol for `Icon.contextRing`. `nil` falls back to a
    /// static glyph, which is what happens before a model's window is known.
    var contextShare: Double?
    /// The value a row currently holds — the resolved effort beside
    /// `/reasoning`. Returning `nil` leaves the trailing column empty.
    var trailingText: (ChatSlashCommandCompletion.Row) -> String? = { _ in nil }
    var onHover: (Int) -> Void = { _ in }
    var onSelect: (ChatSlashCommandCompletion.Row) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(completion.rows.enumerated()), id: \.element.id) { index, row in
                    self.row(row, isSelected: index == selection)
                        .onHover { inside in
                            if inside { onHover(index) }
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Naturally sized until it would be taller than this, which three
        // commands never are. `basedOnSize` is what stops an un-scrollable list
        // from rubber-banding when the pointer crosses it.
        .frame(maxHeight: Metrics.Chat.slashMenuMaxHeight)
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .composerBlock()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Commands"))
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
        case .command(let command):
            switch command.icon {
            case .symbol(let name):
                Image(systemName: name).font(.caption)
            case .contextRing:
                if let contextShare {
                    ContextRing(share: contextShare)
                } else {
                    Image(systemName: "circle.dashed").font(.caption)
                }
            }
        case .option:
            // Options are children of the row above them, and a second glyph
            // column would make them read as commands of their own.
            Color.clear
        }
    }

    private func title(of row: ChatSlashCommandCompletion.Row) -> String {
        switch row {
        case .command(let command): command.name
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

// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindPresentation

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
    var contextShare: Double?
    /// The value a row currently holds — the resolved effort beside
    /// `/reasoning`. Returning `nil` leaves the trailing column empty.
    var trailingText: (ChatSlashCommandCompletion.Row) -> String? = { _ in nil }
    var onHover: (Int) -> Void = { _ in }
    var onSelect: (ChatSlashCommandCompletion.Row) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(completion.rows.enumerated()), id: \.element.id) { index, row in
                        self.row(row, isSelected: index == selection)
                            .id(row.id)
                            .onHover { inside in
                                if inside { onHover(index) }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { scrollSelectionIntoView(using: proxy) }
            .onChange(of: scrollRequest) { _, _ in scrollSelectionIntoView(using: proxy) }
            .onChange(of: completion.rows) { _, _ in scrollSelectionIntoView(using: proxy) }
        }
        // Naturally sized until it would be taller than this. `basedOnSize` is
        // what stops a short list from rubber-banding when the pointer crosses
        // it while longer command and option lists remain scrollable.
        .frame(height: listHeight)
        .composerBlock()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Assistant.commands))
    }

    private var listHeight: CGFloat {
        Metrics.Chat.slashMenuHeight(rowCount: completion.rows.count)
    }

    private func scrollSelectionIntoView(using proxy: ScrollViewProxy) {
        guard completion.rows.indices.contains(selection) else { return }
        proxy.scrollTo(completion.rows[selection].id)
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
            .frame(
                maxWidth: .infinity,
                minHeight: Metrics.Chat.slashMenuRowHeight,
                maxHeight: Metrics.Chat.slashMenuRowHeight,
                alignment: .leading
            )
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

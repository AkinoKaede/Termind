// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import SwiftUI
import TermindApplication
import TermindPresentation

/// The touch-first counterpart to the macOS slash palette.
///
/// It floats above the composer so filtering commands never moves the transcript
/// or the controls under the native multiline text field. A command with fixed
/// choices advances to an option page; free-text commands run immediately when
/// tapped and can still be typed in full before the Send button is pressed.
struct MobileSlashCommandPanel: View {
    let completion: ChatSlashCommandCompletion
    var contextShare: Double?
    var hasOptions: (ChatSlashCommand) -> Bool
    var trailingText: (ChatSlashCommandCompletion.Row) -> String?
    var isCurrent: (ChatSlashCommandCompletion.Row) -> Bool
    var onSelect: (ChatSlashCommandCompletion.Row) -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight = 64.0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(completion.rows.enumerated()), id: \.element.id) { index, row in
                    rowButton(row)
                    if index < completion.rows.count - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .scrollIndicators(.visible)
        .frame(height: panelHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(AppStrings.Assistant.commands))
    }

    private var panelHeight: CGFloat {
        rowHeight * CGFloat(min(completion.rows.count, 3))
    }

    private func rowButton(_ row: ChatSlashCommandCompletion.Row) -> some View {
        Button {
            onSelect(row)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                commandIcon(for: row)
                    .frame(width: 28, height: 28)

                rowLabels(row)
                    .fixedSize(horizontal: false, vertical: true)

                if isCurrent(row) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text(AppStrings.Common.current))
                        .fixedSize()
                } else if let trailing = trailingText(row) {
                    Text(trailing)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .fixedSize(horizontal: true, vertical: false)
                }

                if case .command(let command) = row, hasOptions(command) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .frame(width: 24, height: 28)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, maxHeight: rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowLabels(_ row: ChatSlashCommandCompletion.Row) -> some View {
        switch row {
        case .command(let command):
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: command.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(verbatim: command.summary)
                    .font(.subheadline).foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .option(_, let option):
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: option.label).font(.callout.weight(.medium)).lineLimit(1)
                Text(verbatim: option.detail.isEmpty ? " " : option.detail)
                    .font(.subheadline).foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func commandIcon(for row: ChatSlashCommandCompletion.Row) -> some View {
        let command: ChatSlashCommand =
            switch row {
            case .command(let command): command
            case .option(let command, _): command
            }
        switch command.icon {
        case .symbol(let name):
            Image(systemName: name).foregroundStyle(Color.primary.opacity(0.62))
        case .contextRing:
            ContextRing(share: contextShare ?? 0, diameter: 18, lineWidth: 2)
        }
    }

}

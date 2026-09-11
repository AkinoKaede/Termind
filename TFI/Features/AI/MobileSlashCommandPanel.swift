import SwiftUI
import TermindApplication

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
    var onBack: () -> Void
    var onClose: () -> Void
    var onSelect: (ChatSlashCommandCompletion.Row) -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight = 78.0
    @ScaledMetric(relativeTo: .callout) private var headerHeight = 44.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
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
        }
        .frame(height: panelHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 7)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Commands"))
    }

    private var optionCommand: ChatSlashCommand? {
        guard case .option(let command, _) = completion.rows.first else { return nil }
        return command
    }

    private var panelHeight: CGFloat {
        min(360, headerHeight + rowHeight * CGFloat(completion.rows.count))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let optionCommand {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                        .frame(width: 36, height: 36)
                        .contentShape(.rect)
                }
                .accessibilityLabel(Text("Back"))

                Text(optionCommand.displayName)
                    .font(.headline)
                    .lineLimit(1)
            } else {
                Label("Commands", systemImage: "slash.circle")
                    .font(.headline)
            }

            Spacer(minLength: 8)

            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 8)
        .frame(minHeight: headerHeight)
    }

    private func rowButton(_ row: ChatSlashCommandCompletion.Row) -> some View {
        Button {
            onSelect(row)
        } label: {
            HStack(spacing: 12) {
                commandIcon(for: row)
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.tint)

                rowLabels(row)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if isCurrent(row) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel(Text("Current"))
                } else if let trailing = trailingText(row) {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if case .command(let command) = row, hasOptions(command) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func rowLabels(_ row: ChatSlashCommandCompletion.Row) -> some View {
        switch row {
        case .command(let command):
            Text(verbatim: "\(command.name)  \(command.displayName)\n\(command.summary)")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .option(_, let option):
            Text(verbatim: option.detail.isEmpty ? option.label : "\(option.label)\n\(option.detail)")
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .lineLimit(3)
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
            Image(systemName: name)
        case .contextRing:
            ZStack {
                Circle().stroke(.tertiary.opacity(0.35), lineWidth: 2)
                if let contextShare {
                    Circle()
                        .trim(from: 0, to: max(0.025, contextShare))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 18, height: 18)
        }
    }

}

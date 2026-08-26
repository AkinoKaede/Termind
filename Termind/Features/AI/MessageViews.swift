import Foundation
import AppKit
import SwiftUI

/// A turn the user sent, drawn as a bubble against the trailing edge.
///
/// No avatar and no "You": alignment and fill already say who is speaking, and
/// a label on every turn is a line of furniture repeated down the whole
/// transcript.
struct UserMessageView: View {
    let message: ChatMessage
    var isCompact = false
    var canEdit = false
    var onEdit: ((String) -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var bubbleWidth: CGFloat = 0
    @State private var hasMarkedText = false
    @FocusState private var editFocused: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.Chat.blockSpacing) {
            HStack(alignment: .top, spacing: 0) {
                // A fixed gutter rather than a percentage of the column: no
                // `GeometryReader`, and the bubble hugs its content instead of
                // being stretched to a fraction of the width.
                Spacer(minLength: isCompact ? Metrics.Chat.compactGutter : Metrics.Chat.gutter)

                messageContent
            }

            MessageActionRow(
                message: message, isUser: true, isVisible: isHovering && !isEditing,
                onEdit: canEdit ? { beginEdit() } : nil
            )
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Includes the otherwise-empty gap above the action row. Without a
        // rectangular hover region, crossing that gap hides the button before
        // the pointer can reach it.
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("You said"))
    }

    private func beginEdit() {
        editText = message.text
        isEditing = true
        editFocused = true
    }

    private var messageContent: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            if !message.contextChips.isEmpty {
                FlowLayout(spacing: Metrics.Space.xs, fillsWidth: false) {
                    ForEach(message.contextChips) { BubbleContextChipView(chip: $0) }
                }
            }
            if !message.images.isEmpty {
                FlowLayout(spacing: Metrics.Space.s, fillsWidth: false) {
                    ForEach(message.images) {
                        BubbleImageView(attachment: $0, isCompact: isCompact)
                    }
                }
            }
            if isEditing { editor } else if !message.text.isEmpty {
                MarkdownView(text: message.text, isAssistant: false, isCompact: isCompact)
            }
        }
        .environment(\.markdownFillsWidth, false)
        .padding(.horizontal, Metrics.Space.l)
        .padding(.vertical, Metrics.Space.m)
        .background(
            .quaternary.opacity(0.5),
            in: .rect(cornerRadius: Metrics.Chat.bubbleRadius)
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.width
        } action: { width in
            // Capture the resting bubble, not the editor. The edit control can
            // then occupy the same silhouette instead of accepting the list's
            // full-width proposal and turning into a second composer.
            if !isEditing { bubbleWidth = width }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: Metrics.Space.s) {
            TextEditor(text: $editText)
                .scrollContentBackground(.hidden)
                .font(.body)
                .focused($editFocused)
                .frame(width: editorContentWidth, height: editorHeight)
                .background {
                    TextViewMarkedTextObserver(hasMarkedText: $hasMarkedText)
                }
                .onKeyPress(.return, phases: .down) { press in
                    guard !hasMarkedText, !press.modifiers.contains(.shift) else {
                        return .ignored
                    }
                    let disallowed: EventModifiers = [.control, .option]
                    guard press.modifiers.intersection(disallowed).isEmpty else {
                        return .ignored
                    }
                    commitEdit()
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    isEditing = false
                    return .handled
                }
                .onAppear { editFocused = true }
            HStack(spacing: Metrics.Space.s) {
                Button("Cancel") { isEditing = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Button("Send", action: commitEdit)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
    }

    private var editorContentWidth: CGFloat {
        let captured = bubbleWidth - (Metrics.Space.l * 2)
        return max(captured, isCompact ? 160 : 200)
    }

    private var editorHeight: CGFloat {
        let estimatedLines = editText.split(
            separator: "\n", omittingEmptySubsequences: false
        ).reduce(0) { count, line in
            count + max(1, Int(ceil(Double(line.count) / 48)))
        }
        return min(160, max(44, CGFloat(estimatedLines * 19 + 12)))
    }

    private func commitEdit() {
        let text = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isEditing = false
        onEdit?(text)
    }
}

private struct BubbleContextChipView: View {
    let chip: ContextChipReference

    var body: some View {
        HStack(spacing: Metrics.Space.xs) {
            Image(systemName: chip.kind.symbol)
                .font(.caption2)
                .frame(width: 12, height: 12)
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.Space.s)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.5), in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

private struct BubbleImageView: View {
    let attachment: AgentImageAttachment
    let isCompact: Bool

    var body: some View {
        if let image = NSImage(data: attachment.data) {
            Image(nsImage: image)
                .resizable()
                // Fill a fixed square from the centre. Portrait, landscape and
                // screenshot batches therefore align instead of producing a
                // different row height for every attachment.
                .scaledToFill()
                .frame(width: tileSide, height: tileSide)
                .clipped()
                .clipShape(.rect(cornerRadius: Metrics.Radius.medium))
                .accessibilityLabel(Text(attachment.label))
        }
    }

    private var tileSide: CGFloat {
        isCompact ? Metrics.Chat.compactImageTile : Metrics.Chat.imageTile
    }
}

/// A turn the assistant produced, drawn with no container at all.
///
/// The reply is the page. A card around it would compete with the tool rows and
/// command cards that genuinely are objects, and those need the emphasis more.
struct AssistantMessageView: View {
    let message: ChatMessage
    var isCompact = false
    var showsTerminalActions = false
    var canFork = false
    var onFork: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Chat.blockSpacing) {
            if !message.text.isEmpty {
                MarkdownView(
                    text: message.text,
                    isStreaming: message.isStreaming,
                    isAssistant: true,
                    isCompact: isCompact
                )
            }

            if message.isStreaming {
                if message.text.isEmpty {
                    WorkingIndicator()
                } else {
                    StreamingCaret()
                }
            } else {
                MessageActionRow(
                    message: message, isUser: false, isVisible: isHovering,
                    onFork: canFork ? onFork : nil
                )
            }

            ForEach(message.commands) { command in
                CommandCardView(
                    command: command, showsTerminalActions: showsTerminalActions
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Assistant said"))
    }
}

/// A quiet, text-only activity indicator. The wording changes occasionally so
/// a long wait does not feel frozen, while the transparent scan supplies the
/// continuous motion shared by running tool titles.
struct WorkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var statusIndex = 0

    private static let statuses = [
        "Working…",
        "Thinking…",
        "Reasoning…",
    ]

    var body: some View {
        Text(Self.statuses[statusIndex])
            // This occupies the exact slot later used by provider reasoning.
            // Matching its typography avoids a baseline jump when the first
            // reasoning delta replaces the placeholder.
            .font(MarkdownTypography.body)
            .foregroundStyle(.secondary)
            .modifier(ScanningTextMask(isActive: true))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.statuses[statusIndex]))
            .task(id: reduceMotion) {
                if reduceMotion {
                    statusIndex = 0
                    return
                }

                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2.8))
                    guard !Task.isCancelled else { return }

                    // Pick any other phrase, so a timer tick always produces a
                    // visible change instead of randomly choosing the same item.
                    let offset = Int.random(in: 1..<Self.statuses.count)
                    statusIndex = (statusIndex + offset) % Self.statuses.count
                }
            }
    }
}

/// Cuts a soft transparent notch out of active text and moves it from leading
/// to trailing, matching the familiar "Thinking" text treatment. The text is
/// the only moving surface; surrounding controls stay still.
struct ScanningTextMask: ViewModifier {
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if isActive, !reduceMotion {
            content.mask {
                GeometryReader { geometry in
                    TimelineView(.animation) { timeline in
                        let duration = 1.55
                        let progress = timeline.date.timeIntervalSinceReferenceDate
                            .truncatingRemainder(dividingBy: duration) / duration
                        // The reference treatment loses roughly one third of
                        // the word at a time: a fully transparent center with
                        // long, soft shoulders rather than a narrow glint.
                        let bandWidth = min(max(geometry.size.width * 0.32, 40), 96)

                        ZStack(alignment: .leading) {
                            Rectangle().fill(.white)

                            LinearGradient(
                                colors: [
                                    .clear,
                                    .white.opacity(0.34),
                                    .white.opacity(0.82),
                                    .white,
                                    .white.opacity(0.82),
                                    .white.opacity(0.34),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: bandWidth)
                            .offset(
                                x: -bandWidth
                                    + (geometry.size.width + bandWidth) * progress
                            )
                            .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                }
            }
        } else {
            content
        }
    }
}

/// Copy and time use opposite reading order for the two speakers, matching the
/// side each message occupies. The row remains in layout while transparent so
/// its hit area bridges the pointer from the message body to the copy button.
private struct MessageActionRow: View {
    let message: ChatMessage
    let isUser: Bool
    let isVisible: Bool
    var onEdit: (() -> Void)?
    var onFork: (() -> Void)?

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            if isUser {
                Spacer(minLength: 0)
                timestamp
                if let onEdit { actionButton("Edit", symbol: "pencil", action: onEdit) }
                CopyButton(text: message.text)
            } else {
                CopyButton(text: message.text)
                if let onFork {
                    actionButton("Fork", symbol: "arrow.triangle.branch", action: onFork)
                }
                timestamp
                Spacer(minLength: 0)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
    }

    private func actionButton(
        _ label: LocalizedStringKey, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private var timestamp: some View {
        Text(ChatMessageTimestampFormatter.string(for: message.createdAt))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .textSelection(.disabled)
    }
}

/// Localized minute-precision metadata for a chat turn. Today omits the date;
/// older messages include the user's short date so restored conversations do
/// not lose temporal context.
nonisolated enum ChatMessageTimestampFormatter {
    static func string(
        for date: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = DateFormatter()
        var calendar = calendar
        calendar.timeZone = timeZone
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// The caret that marks a reply still being written.
///
/// Its own view so the blink state stays local and does not invalidate the
/// message body on every pulse.
private struct StreamingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDim = false

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.Chat.caretWidth / 2)
            .fill(.primary)
            .frame(width: Metrics.Chat.caretWidth, height: Metrics.Chat.caretHeight)
            .opacity(isDim ? 0.15 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(Motion.statusPulse) { isDim = true }
            }
            .accessibilityLabel(Text("Still writing"))
    }
}

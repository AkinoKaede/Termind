import Foundation
import SwiftUI

/// A turn the user sent, drawn as a bubble against the trailing edge.
///
/// No avatar and no "You": alignment and fill already say who is speaking, and
/// a label on every turn is a line of furniture repeated down the whole
/// transcript.
struct UserMessageView: View {
    let message: ChatMessage
    var isCompact = false

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: Metrics.Chat.blockSpacing) {
            HStack(alignment: .top, spacing: 0) {
                // A fixed gutter rather than a percentage of the column: no
                // `GeometryReader`, and the bubble hugs its content instead of
                // being stretched to a fraction of the width.
                Spacer(minLength: isCompact ? Metrics.Chat.compactGutter : Metrics.Chat.gutter)

                MarkdownView(text: message.text, isAssistant: false, isCompact: isCompact)
                    // The bubble is sized by what is in it. Without this the block
                    // views claim every point they are offered, and "ok" gets a
                    // bubble as wide as an essay.
                    .environment(\.markdownFillsWidth, false)
                    .padding(.horizontal, Metrics.Space.l)
                    .padding(.vertical, Metrics.Space.m)
                    .background(
                        .quaternary.opacity(0.5),
                        in: .rect(cornerRadius: Metrics.Chat.bubbleRadius)
                    )
            }

            MessageActionRow(message: message, isUser: true, isVisible: isHovering)
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
}

/// A turn the assistant produced, drawn with no container at all.
///
/// The reply is the page. A card around it would compete with the tool rows and
/// command cards that genuinely are objects, and those need the emphasis more.
struct AssistantMessageView: View {
    let message: ChatMessage
    var isCompact = false

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
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text("Thinking"))
                } else {
                    StreamingCaret()
                }
            } else {
                MessageActionRow(message: message, isUser: false, isVisible: isHovering)
            }

            ForEach(message.commands) { command in
                CommandCardView(command: command)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Assistant said"))
    }
}

/// Copy and time use opposite reading order for the two speakers, matching the
/// side each message occupies. The row remains in layout while transparent so
/// its hit area bridges the pointer from the message body to the copy button.
private struct MessageActionRow: View {
    let message: ChatMessage
    let isUser: Bool
    let isVisible: Bool

    var body: some View {
        HStack(spacing: Metrics.Space.s) {
            if isUser {
                Spacer(minLength: 0)
                timestamp
                CopyButton(text: message.text)
            } else {
                CopyButton(text: message.text)
                timestamp
                Spacer(minLength: 0)
            }
        }
        .opacity(isVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isVisible)
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

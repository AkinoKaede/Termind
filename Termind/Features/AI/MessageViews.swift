import SwiftUI

/// A turn the user sent, drawn as a bubble against the trailing edge.
///
/// No avatar and no "You": alignment and fill already say who is speaking, and
/// a label on every turn is a line of furniture repeated down the whole
/// transcript.
struct UserMessageView: View {
    let message: ChatMessage
    var isCompact = false

    var body: some View {
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
                actions
            }

            ForEach(message.commands) { command in
                CommandCardView(command: command)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Assistant said"))
    }

    /// Copying the whole reply, which a stack of block views cannot be framed
    /// and dragged over the way a single `Text` could. Paying that back with a
    /// button is deliberate — losing it quietly would not be.
    private var actions: some View {
        HStack(spacing: Metrics.Space.s) {
            CopyButton(text: message.text)
            Spacer(minLength: 0)
        }
        .opacity(isHovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: isHovering)
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

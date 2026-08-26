import SwiftUI

/// How full the model's context window is, as a ring.
///
/// One view rather than three, because it appears in three places that must
/// agree: the composer's model menu label, the `/compact` row of the command
/// palette, and anywhere else the size of a conversation is stated. A second
/// implementation would be a second answer to the same question.
///
/// Built from a trimmed `Circle` rather than a `Canvas` deliberately. A shape is
/// a plain SwiftUI view and renders wherever any view renders — including a
/// `Menu` label, which on macOS is bridged into AppKit and is not somewhere to
/// find out that an imperative drawing context was unsupported.
struct ContextRing: View {
    /// 0...1. `AgentContextEstimate.share(of:)` clamps before this is reached.
    let share: Double
    var diameter: CGFloat = 11
    var lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            // A filled grey disc, not just a thin track. The ring sits in a row
            // of text at 11pt, and an unfilled outline at that size reads as a
            // stray glyph — the disc is what makes it look like a gauge with
            // something left in it.
            Circle()
                .fill(.quaternary)
            Circle()
                .trim(from: 0, to: max(0, min(1, share)))
                .stroke(
                    Self.tint(for: share),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                // `trim` starts at three o'clock; every other dial starts at
                // twelve.
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    /// Blue for the ordinary case, then orange, then red.
    ///
    /// The thresholds are where the *reader's* options change rather than round
    /// numbers: past 75% a long tool result may no longer fit, and past 90% the
    /// next turn is likely to be the one that compacts. Below that it is just a
    /// quantity, and a quantity in a warning colour is a warning nobody asked
    /// for — which is also why the Plan chip beside it is grey and this is not.
    static func tint(for share: Double) -> Color {
        switch share {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }
}

/// What the context is made of, as rows of a menu.
///
/// The counts are in a right-aligned column, which is what a column of numbers
/// is for: they are read against each other, and a ragged edge makes "38k" and
/// "3.8k" look the same size at a glance.
///
/// That alignment is why each row is an `HStack` with a `Spacer` rather than one
/// padded string. macOS bridges `Menu` content into `NSMenu`, so a plain `Text`
/// becomes a menu-item title and there is no way to align *within* a title —
/// padding with figure spaces only lines up digits, and these labels are words.
/// The ring stays on the menu's *label*, which is an ordinary view either way.
///
/// The point is not the total — that is on the label the reader just clicked —
/// but the split under it. "38k of your 62k is tool output" is what makes
/// compacting an informed choice rather than a guess.
struct ContextBreakdownMenuItems: View {
    let estimate: AgentContextEstimate
    /// `nil` when the model's window is unknown, which is common for gateway
    /// providers. The parts still mean something; the share does not.
    let contextWindow: Int?
    let cachedInputTokens: Int

    var body: some View {
        Section(headline) {
            ForEach(AgentContextEstimate.Part.allCases) { part in
                let tokens = estimate.tokens(part)
                if tokens > 0 {
                    row(part.displayName, tokens)
                }
            }
            if cachedInputTokens > 0 {
                row(String(localized: "Served from cache"), cachedInputTokens)
            }
        }
    }

    private func row(_ name: String, _ tokens: Int) -> some View {
        HStack(spacing: Metrics.Space.m) {
            Text(name)
            Spacer(minLength: Metrics.Space.m)
            Text(Self.compact(tokens))
                // Monospaced digits so the column stays a column as the numbers
                // change under a running turn, rather than shuffling by a
                // fraction of a character every time a 1 becomes a 4.
                .monospacedDigit()
        }
        // The width is the whole reason this aligns. A menu item sizes to its
        // content, so a `Spacer` inside one has nothing to expand into and
        // collapses to its minimum — every row then ends up a different width
        // and the numbers stagger. Fixing the width gives the spacer room to
        // push against, which is what puts the counts in a column.
        .frame(width: Metrics.Chat.contextBreakdownWidth, alignment: .leading)
    }

    private var headline: String {
        // The tilde is the whole disclosure. With no measured turn behind it
        // this is a character count, and a number presented as though the
        // provider had said it is one people would plan against.
        let prefix = estimate.isMeasured ? "" : "~"
        guard let contextWindow, contextWindow > 0 else {
            return String(localized: "Context: \(prefix)\(Self.compact(estimate.total)) tokens")
        }
        let percent = Int((estimate.share(of: contextWindow) ?? 0) * 100)
        return String(
            localized:
                "Context: \(prefix)\(Self.compact(estimate.total)) of \(Self.compact(contextWindow)) (\(percent)%)"
        )
    }

    /// Pads with figure spaces rather than a `Grid`, because this text becomes
    /// an `NSMenuItem` title. U+2007 is the width of a digit in most faces, so
    /// the counts line up without assuming a monospaced menu font.
    private static func row(_ name: String, _ tokens: Int) -> String {
        let value = compact(tokens)
        let padding = max(1, 22 - name.count - value.count)
        return name + String(repeating: "\u{2007}", count: padding) + value
    }

    /// `62.4k`, not `62,431`. A gauge is read at a glance, and the last three
    /// digits of a token count have never changed anyone's mind.
    static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<10_000: String(format: "%.1fk", Double(tokens) / 1_000)
        case ..<1_000_000: "\(tokens / 1_000)k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }
}

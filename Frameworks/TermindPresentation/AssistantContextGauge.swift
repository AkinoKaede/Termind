import AgentKit
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
public struct ProgressRing: View {
    let share: Double
    let tint: Color
    public var diameter: CGFloat = 11
    public var lineWidth: CGFloat = 2

    public init(share: Double, tint: Color, diameter: CGFloat = 11, lineWidth: CGFloat = 2) {
        self.share = share
        self.tint = tint
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.3), lineWidth: lineWidth)
                .padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: max(0, min(1, share)))
                .stroke(
                    tint,
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
}

public struct ContextRing: View {
    /// 0...1. `AgentContextEstimate.share(of:)` clamps before this is reached.
    let share: Double
    public var diameter: CGFloat = 11
    public var lineWidth: CGFloat = 2

    public init(share: Double, diameter: CGFloat = 11, lineWidth: CGFloat = 2) {
        self.share = share
        self.diameter = diameter
        self.lineWidth = lineWidth
    }

    public var body: some View {
        ProgressRing(
            share: share, tint: Self.tint(for: share),
            diameter: diameter, lineWidth: lineWidth
        )
    }

    /// Blue for the ordinary case, then orange, then red.
    ///
    /// The thresholds are where the *reader's* options change rather than round
    /// numbers: past 75% a long tool result may no longer fit, and past 90% the
    /// next turn is likely to be the one that compacts. Below that it is just a
    /// quantity, and a quantity in a warning colour is a warning nobody asked
    /// for — which is also why the Plan chip beside it is grey and this is not.
    public static func tint(for share: Double) -> Color {
        switch share {
        case ..<0.75: .accentColor
        case ..<0.9: .orange
        default: .red
        }
    }
}

/// What the context is made of, laid out in a real two-column surface.
///
/// A native `NSMenu` reserves a trailing accessory column for submenu arrows
/// and shortcuts. No amount of string padding can place text in that column —
/// it only makes the menu wider. Keeping this in the model picker's popover
/// gives `Spacer` an actual width and makes the value edge truthful.
public struct ContextBreakdownView: View {
    public let estimate: AgentContextEstimate
    /// `nil` when the model's window is unknown, which is common for gateway
    /// providers. The parts still mean something; the share does not.
    public let contextWindow: Int?
    public let cachedInputTokens: Int
    public let showsTitle: Bool

    public init(
        estimate: AgentContextEstimate, contextWindow: Int?, cachedInputTokens: Int,
        showsTitle: Bool = true
    ) {
        self.estimate = estimate
        self.contextWindow = contextWindow
        self.cachedInputTokens = cachedInputTokens
        self.showsTitle = showsTitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text(TermindCopy.Assistant.context)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.name)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 16)
                    Text(row.value)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .font(.callout)
            }
        }
    }

    private var rows: [(name: String, value: String)] {
        var rows = [(String(localized: "Usage"), usageValue)]
        for part in AgentContextEstimate.Part.allCases {
            let tokens = estimate.tokens(part)
            if tokens > 0 {
                rows.append((part.displayName, Self.compact(tokens)))
            }
        }
        if cachedInputTokens > 0 {
            rows.append((String(localized: "Served from cache"), Self.compact(cachedInputTokens)))
        }
        return rows
    }

    private var usageValue: String {
        // The tilde is the whole disclosure. With no measured turn behind it
        // this is a character count, and a number presented as though the
        // provider had said it is one people would plan against.
        let prefix = estimate.isMeasured ? "" : "~"
        guard let contextWindow, contextWindow > 0 else {
            return String(localized: "\(prefix)\(Self.compact(estimate.total)) tokens")
        }
        let percent = Int((estimate.share(of: contextWindow) ?? 0) * 100)
        return String(
            localized:
                "\(prefix)\(Self.compact(estimate.total)) of \(Self.compact(contextWindow)) (\(percent)%)"
        )
    }

    /// `62.4k`, not `62,431`. A gauge is read at a glance, and the last three
    /// digits of a token count have never changed anyone's mind.
    public static func compact(_ tokens: Int) -> String {
        switch tokens {
        case ..<1_000: "\(tokens)"
        case ..<10_000: String(format: "%.1fk", Double(tokens) / 1_000)
        case ..<1_000_000: "\(tokens / 1_000)k"
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }
}

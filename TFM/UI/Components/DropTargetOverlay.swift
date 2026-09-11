import SwiftUI

nonisolated struct DropTargetPresentation: Equatable, Sendable {
    nonisolated enum Tone: Equatable, Sendable {
        case accent
        case unavailable
    }

    let title: String
    let detail: String
    let systemImage: String
    var tone: Tone = .accent
}

/// One unmistakable drop affordance for every full-surface destination.
///
/// The content under it remains visible enough to retain place, while the
/// moving dashed border and the compact glass card make the pending action
/// legible over a terminal, a file list, or a transcript.
struct DropTargetOverlay: View {
    let presentation: DropTargetPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatesSymbol = false

    private var tint: Color {
        presentation.tone == .unavailable ? .orange : .accentColor
    }

    var body: some View {
        ZStack {
            tint.opacity(0.09)

            RoundedRectangle(cornerRadius: Metrics.Radius.large)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(Metrics.Space.m)

            VStack(spacing: Metrics.Space.s) {
                Image(systemName: presentation.systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(
                        .bounce.up,
                        options: reduceMotion ? .nonRepeating : .repeating.speed(0.55),
                        value: animatesSymbol
                    )
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metrics.Space.xl)
            .padding(.vertical, Metrics.Space.l)
            .termindTransientOverlaySurface()
        }
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.96))
        )
        .onAppear { animatesSymbol = true }
    }
}

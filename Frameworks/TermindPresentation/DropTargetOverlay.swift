import SwiftUI

public nonisolated struct DropTargetPresentation: Equatable, Sendable {
    public nonisolated enum Tone: Equatable, Sendable {
        case accent
        case unavailable
    }

    public let title: String
    public let detail: String
    public let systemImage: String
    public var tone: Tone

    public init(
        title: String,
        detail: String,
        systemImage: String,
        tone: Tone = .accent
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tone = tone
    }
}

/// One unmistakable drop affordance for every full-surface destination.
///
/// The content under it remains visible enough to retain place, while the
/// moving dashed border and the compact glass card make the pending action
/// legible over a terminal, a file list, or a transcript.
public struct DropTargetOverlay: View {
    public let presentation: DropTargetPresentation

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animatesSymbol = false

    private let cornerRadius: CGFloat = 10
    private var tint: Color {
        presentation.tone == .unavailable ? .orange : .accentColor
    }

    public init(presentation: DropTargetPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        ZStack {
            tint.opacity(0.09)

            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )
                .padding(8)

            VStack(spacing: 6) {
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
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .modifier(DropTargetCardSurface(cornerRadius: cornerRadius))
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .transition(
            reduceMotion
                ? .opacity
                : .opacity.combined(with: .scale(scale: 0.96))
        )
        .onAppear { animatesSymbol = true }
    }
}

private struct DropTargetCardSurface: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
        }
    }
}

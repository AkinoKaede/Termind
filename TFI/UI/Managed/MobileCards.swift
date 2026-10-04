import SwiftUI
import TermindPresentation
import UIKit

struct MobileCardPage<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) { content }
                .padding(16)
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }
}

struct MobileCardGrid<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                count: MobileCardLayout.columns(
                    width: width,
                    accessibilitySize: typeSize.isAccessibilitySize)),
            alignment: .leading, spacing: 12
        ) { content }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }
}

struct MobileCardSection<Content: View>: View {
    let title: LocalizedStringResource
    var count: Int? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                if let count {
                    Text(count, format: .number).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }.accessibilityAddTraits(.isHeader)
            content
        }
    }
}

private struct MobileCardSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            surface(
                content,
                shape: ConcentricRectangle(corners: .concentric(minimum: 20), isUniform: true),
                containerRadius: 20
            )
        } else {
            surface(
                content, shape: RoundedRectangle(cornerRadius: 10, style: .continuous),
                containerRadius: 10)
        }
    }

    private func surface<S: Shape>(
        _ content: Content, shape: S, containerRadius: CGFloat
    ) -> some View {
        filledSurface(content, shape: shape)
            .overlay {
                // The final clip keeps the inner half, preserving the existing one-point border.
                shape
                    .stroke(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .containerShape(
                RoundedRectangle(cornerRadius: containerRadius, style: .continuous)
            )
            .contentShape([.interaction, .contextMenuPreview], shape)
    }

    @ViewBuilder private func filledSurface<S: Shape>(_ content: Content, shape: S) -> some View {
        if #available(iOS 26, *), !reduceTransparency, contrast != .increased {
            // Keep dense text legible while retaining the system's glass edge and lighting.
            content
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground).opacity(0.9), in: shape
                )
                .glassEffect(.regular, in: shape)
        } else {
            content.background(Color(uiColor: .secondarySystemGroupedBackground), in: shape)
        }
    }
}

extension View {
    func mobileCardSurface() -> some View { modifier(MobileCardSurface()) }
}

struct MobileCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            .padding(16)
            .frame(minHeight: MobileCardLayout.minimumHeight, alignment: .topLeading)
            .mobileCardSurface()
    }
}

/// The primary action fills the card. Secondary actions are available from the card's context menu.
struct MobileActionCard<Content: View, Actions: View>: View {
    let alignment: Alignment
    let action: () -> Void
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    init(
        alignment: Alignment = .topLeading,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.alignment = alignment
        self.action = action
        self.content = content()
        self.actions = actions()
    }

    private var cardSurface: some View {
        content.frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            .padding(16)
            .frame(
                maxWidth: .infinity, minHeight: MobileCardLayout.minimumHeight,
                alignment: alignment
            )
            .mobileCardSurface()
    }

    var body: some View {
        Button(action: action) {
            cardSurface
                .contextMenu {
                    actions
                }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
    }
}

// Keep the mobile API while sharing the rendering with desktop Snippet cards.
typealias MobileCardIcon = LibraryCardIcon
typealias MobileCardChip = LibraryCardChip

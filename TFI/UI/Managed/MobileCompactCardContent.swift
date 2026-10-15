import SwiftUI

struct MobileCompactCardContent<Icon: View>: View {
    let title: String
    var status: Text = Text(verbatim: "")
    @ViewBuilder var icon: Icon
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 8) {
            icon.accessibilityHidden(true)
            Group {
                if typeSize.isAccessibilitySize {
                    Text(verbatim: title)
                } else {
                    Text(verbatim: title).lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(status)
    }
}

struct MobileCompactCardBadge: View {
    let symbol: String
    var tint: Color = .orange

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 16, height: 16)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: .circle)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

/// A square minimum, not a fixed aspect ratio: large text can make the card taller.
struct MobileCompactCardLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let proposedWidth = proposal.width ?? content.sizeThatFits(.unspecified).width
        let width = proposedWidth.isFinite ? max(0, proposedWidth) : content.sizeThatFits(.unspecified).width
        let height = content.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: max(width, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

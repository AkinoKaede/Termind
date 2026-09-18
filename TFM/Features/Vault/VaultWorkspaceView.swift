import SwiftUI

struct VaultWorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VaultWorkspaceContent(reduceMotion: reduceMotion)
    }
}

struct VaultWorkspaceContent: View {
    @Environment(WindowModel.self) private var window
    let reduceMotion: Bool

    var body: some View {
        GeometryReader { geometry in
            let showsDetail = window.vaultWorkRoute != nil
            let showsList = !showsDetail || geometry.size.width >= Metrics.VaultContent.splitMinWidth

            VaultWorkspaceLayout(showsDetail: showsDetail) {
                VaultView(pages: window.vaultPages)
                    .opacity(showsList ? 1 : 0)
                    .allowsHitTesting(showsList)
                    .disabled(!showsList)
                    .accessibilityHidden(!showsList)

                Divider()
                    .opacity(showsDetail && showsList ? 1 : 0)

                ZStack {
                    if let route = window.vaultWorkRoute {
                        VaultWorkDetailView(route: route)
                            .id(route)
                            .transition(.opacity)
                    }
                }
                .clipped()
                .opacity(showsDetail ? 1 : 0)
                .allowsHitTesting(showsDetail)
                .disabled(!showsDetail)
                .accessibilityHidden(!showsDetail)
            }
            .clipped()
            .animation(Motion.panel(reduceMotion: reduceMotion), value: window.vaultWorkRoute)
        }
    }
}

/// The children never change identity at the breakpoint. A covered list keeps
/// its last visible size so returning from an editor also keeps its scroll position.
struct VaultWorkspaceLayout: Layout {
    var showsDetail: Bool
    private var expansion: CGFloat

    init(showsDetail: Bool) {
        self.showsDetail = showsDetail
        expansion = showsDetail ? 1 : 0
    }

    var animatableData: CGFloat {
        get { expansion }
        set { expansion = newValue }
    }

    struct Cache {
        var listSize: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }
        let split = bounds.width >= Metrics.VaultContent.splitMinWidth
        let progress = min(1, max(0, expansion))
        // Keep the editor at its open width even while it leaves. Only its
        // position and the list's reserved space animate, never the form's width.
        let detailWidth =
            split ? min(Metrics.VaultDetail.ideal, bounds.width - Metrics.VaultContent.min - 1) : bounds.width
        let listWidth = split ? bounds.width - (detailWidth + 1) * progress : bounds.width
        let listIsVisible = !showsDetail || split
        let listSize = listIsVisible ? CGSize(width: listWidth, height: bounds.height) : cache.listSize ?? bounds.size
        if listIsVisible { cache.listSize = listSize }

        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(listSize))
        subviews[1].place(
            at: CGPoint(x: bounds.minX + listWidth, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: split ? 1 : 0, height: bounds.height)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX - detailWidth * progress, y: bounds.minY), anchor: .topLeading,
            proposal: ProposedViewSize(width: detailWidth, height: bounds.height)
        )
    }
}

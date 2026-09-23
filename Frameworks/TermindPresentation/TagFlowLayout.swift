import SwiftUI

public struct TagFlowLayout: Layout {
    public enum WidthSizing: Sendable {
        case proposed
        case intrinsic
    }

    private let spacing: CGFloat
    private let widthSizing: WidthSizing

    public init(spacing: CGFloat, widthSizing: WidthSizing) {
        self.spacing = spacing
        self.widthSizing = widthSizing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let width = TagFlowGeometry.width(
            proposal: proposal,
            naturalWidth: TagFlowGeometry.naturalWidth(sizes: sizes, spacing: spacing),
            sizing: widthSizing
        )
        return TagFlowGeometry.size(sizes: sizes, width: width, spacing: spacing)
    }

    public func placeSubviews(
        in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in TagFlowGeometry.rows(sizes: sizes, width: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += row.height + spacing
        }
    }
}

nonisolated enum TagFlowGeometry {
    struct RowRun: Equatable {
        var indices: [Int] = []
        var height: CGFloat = 0
    }

    static func naturalWidth(sizes: [CGSize], spacing: CGFloat) -> CGFloat {
        sizes.reduce(CGFloat.zero) { width, size in
            width + size.width + (width == 0 ? 0 : spacing)
        }
    }

    static func width(
        proposal: ProposedViewSize, naturalWidth: CGFloat, sizing: TagFlowLayout.WidthSizing
    ) -> CGFloat {
        switch sizing {
        case .proposed:
            return proposal.replacingUnspecifiedDimensions().width
        case .intrinsic:
            guard let proposedWidth = proposal.width else { return naturalWidth }
            return proposedWidth.isFinite ? max(0, proposedWidth) : naturalWidth
        }
    }

    static func size(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> CGSize {
        let rows = rows(sizes: sizes, width: width, spacing: spacing)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    static func rows(sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [RowRun] {
        var rows: [RowRun] = []
        var current = RowRun()
        var x: CGFloat = 0

        for index in sizes.indices {
            let size = sizes[index]
            // The first chip in a row is always kept, even when it is wider than the available width.
            if !current.indices.isEmpty && x + size.width > width {
                rows.append(current)
                current = RowRun()
                x = 0
            }
            current.indices.append(index)
            current.height = max(current.height, size.height)
            x += size.width + spacing
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

import SwiftUI

nonisolated enum MetricsDetailPage: CaseIterable {
    case status, processes

    static func showsBothColumns(width: CGFloat) -> Bool { width >= 700 }
}

/// Both native scroll views stay mounted. A covered panel keeps its last visible
/// size so switching pages or resizing cannot reset its table or scroll position.
struct MetricsDetailLayout: Layout {
    var split: Bool
    var page: MetricsDetailPage

    struct Cache {
        var statusSize: CGSize?
        var processSize: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 2 else { return }
        let statusWidth = split ? min(400, max(270, (bounds.width + 32) * 0.38)) : bounds.width
        let processWidth = split ? max(0, bounds.width - statusWidth - 16) : bounds.width
        let showsStatus = split || page == .status
        let showsProcesses = split || page == .processes
        let statusSize =
            showsStatus
            ? CGSize(width: statusWidth, height: bounds.height) : cache.statusSize ?? bounds.size
        let processSize =
            showsProcesses
            ? CGSize(width: processWidth, height: bounds.height) : cache.processSize ?? bounds.size
        if showsStatus { cache.statusSize = statusSize }
        if showsProcesses { cache.processSize = processSize }

        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(statusSize))
        subviews[1].place(
            at: CGPoint(x: split ? bounds.minX + statusWidth + 16 : bounds.minX, y: bounds.minY),
            anchor: .topLeading, proposal: ProposedViewSize(processSize))
    }
}

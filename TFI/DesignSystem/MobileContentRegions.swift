import SwiftUI

/// Frames use SwiftUI's leading-origin coordinates. ReservedRegion.frame already includes its margins.
nonisolated struct MobileReservedRegion: Equatable {
    enum Kind { case division, occlusion }
    var kind: Kind
    var frame: CGRect
    var isActive = true
}

nonisolated struct MobileContentRegions: Equatable {
    struct Pair: Equatable {
        var first: CGRect
        var second: CGRect
    }

    var continuous: CGRect
    var split: Pair?
    var hasActiveDivision: Bool

    init(size: CGSize, reserved: [MobileReservedRegion]) {
        let bounds = CGRect(origin: .zero, size: size)
        let active = reserved.filter { $0.isActive && $0.frame.intersects(bounds) }
        hasActiveDivision = active.contains { $0.kind == .division }
        let obstacles = active.map(\.frame)
        continuous = Self.largestRectangle(in: bounds, avoiding: obstacles)
        for division in active where division.kind == .division {
            let frame = division.frame.intersection(bounds)
            let first: CGRect
            let second: CGRect
            if division.frame.height >= division.frame.width {
                first = CGRect(x: 0, y: 0, width: frame.minX, height: size.height)
                second = CGRect(x: frame.maxX, y: 0, width: size.width - frame.maxX, height: size.height)
            } else {
                first = CGRect(x: 0, y: 0, width: size.width, height: frame.minY)
                second = CGRect(x: 0, y: frame.maxY, width: size.width, height: size.height - frame.maxY)
            }
            let pair = Pair(
                first: Self.largestRectangle(in: first, avoiding: obstacles),
                second: Self.largestRectangle(in: second, avoiding: obstacles))
            if Self.isUsable(pair.first) && Self.isUsable(pair.second) {
                split = pair
                break
            }
        }
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        rect.width >= 1 && rect.height >= 1 && rect.width.isFinite && rect.height.isFinite
    }

    /// Keep overlapping candidates: disjoint subtraction can discard the largest continuous rectangle.
    private static func largestRectangle(in bounds: CGRect, avoiding obstacles: [CGRect]) -> CGRect {
        guard isUsable(bounds) else { return .zero }
        var candidates = [bounds]
        for obstacle in obstacles {
            candidates = candidates.flatMap { candidate -> [CGRect] in
                let cut = candidate.intersection(obstacle)
                guard !cut.isNull, cut.width > 0, cut.height > 0 else { return [candidate] }
                return [
                    CGRect(
                        x: candidate.minX, y: candidate.minY, width: candidate.width,
                        height: cut.minY - candidate.minY),
                    CGRect(
                        x: candidate.minX, y: cut.maxY, width: candidate.width,
                        height: candidate.maxY - cut.maxY),
                    CGRect(
                        x: candidate.minX, y: candidate.minY, width: cut.minX - candidate.minX,
                        height: candidate.height),
                    CGRect(
                        x: cut.maxX, y: candidate.minY, width: candidate.maxX - cut.maxX,
                        height: candidate.height),
                ].filter(isUsable)
            }
            // Region counts are small, but remove duplicates and contained candidates at each step.
            var maximal: [CGRect] = []
            for candidate in candidates {
                if maximal.contains(where: { $0.contains(candidate) }) { continue }
                maximal.removeAll { candidate.contains($0) }
                maximal.append(candidate)
            }
            candidates = maximal
        }
        return candidates.sorted {
            let leftArea = $0.width * $0.height
            let rightArea = $1.width * $1.height
            if leftArea != rightArea { return leftArea > rightArea }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }.first ?? .zero
    }

    func assistant(interactionHeight: CGFloat) -> Pair {
        let interactionRegion = split?.second ?? continuous
        let height = min(max(0, interactionHeight), interactionRegion.height)
        let interaction = CGRect(
            x: interactionRegion.minX, y: interactionRegion.maxY - height,
            width: interactionRegion.width, height: height)
        let transcript =
            split?.first
            ?? CGRect(
                x: continuous.minX, y: continuous.minY,
                width: continuous.width, height: max(0, continuous.height - height))
        return Pair(first: transcript, second: interaction)
    }
}

extension EnvironmentValues {
    /// Container-local region injection for previews and deterministic layout regression tests.
    @Entry var mobileReservedRegions: [MobileReservedRegion]? = nil
}

struct MobileRegionReader<Content: View>: View {
    @Environment(\.mobileReservedRegions) private var override
    @ViewBuilder var content: (MobileContentRegions) -> Content

    var body: some View {
        GeometryReader { geometry in
            content(MobileContentRegions(size: geometry.size, reserved: regions(in: geometry)))
        }
    }

    private func regions(in geometry: GeometryProxy) -> [MobileReservedRegion] {
        if let override { return override }
        if #available(iOS 27.1, *) {
            // The default mirrored query matches Layout placement in both LTR and RTL.
            return geometry.reservedRegions(kind: .division).map {
                MobileReservedRegion(kind: .division, frame: $0.frame, isActive: $0.isActive)
            }
                + geometry.reservedRegions(kind: .occlusion).map {
                    MobileReservedRegion(kind: .occlusion, frame: $0.frame, isActive: $0.isActive)
                }
        }
        return []
    }
}

/// Never replace or reparent a native surface when the device folds. Covered panes retain their last valid size.
struct MobilePaneLayout: Layout {
    var frames: [CGRect?]

    struct Cache { var sizes: [Int: CGSize] = [:] }
    func makeCache(subviews: Subviews) -> Cache { Cache() }
    func updateCache(_ cache: inout Cache, subviews: Subviews) {}

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        for (index, subview) in subviews.enumerated() {
            let frame = frames.indices.contains(index) ? frames[index] : nil
            if let frame, MobileContentRegions.isUsable(frame) { cache.sizes[index] = frame.size }
            let size = cache.sizes[index] ?? CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
            let origin = frame?.origin ?? .zero
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }
}

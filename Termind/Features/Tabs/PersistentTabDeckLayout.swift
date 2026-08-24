import SwiftUI

/// The identity a tab contributes to `PersistentTabDeckLayout`.
private nonisolated struct PersistentTabDeckIDKey: LayoutValueKey {
    static let defaultValue: Workspace.ID? = nil
}

/// Whether a tab is the one the deck currently presents.
private nonisolated struct PersistentTabDeckActiveKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    func persistentTabDeckValue(id: Workspace.ID, isActive: Bool) -> some View {
        layoutValue(key: PersistentTabDeckIDKey.self, value: id)
            .layoutValue(key: PersistentTabDeckActiveKey.self, value: isActive)
    }
}

/// Per-tab proposals for a deck whose children must remain mounted.
///
/// The visible tab tracks the deck bounds. Hidden tabs keep their last visible
/// size so a sidebar animation cannot recursively lay out every parked split
/// tree and native terminal surface. A tab that has never been visible captures
/// the first usable deck size as its parking size.
nonisolated struct PersistentTabDeckSizingState {
    private var sizes: [Workspace.ID: CGSize] = [:]

    mutating func size(
        for id: Workspace.ID,
        isActive: Bool,
        containerSize: CGSize
    ) -> CGSize {
        if isActive {
            if containerSize.isUsableLayoutSize { sizes[id] = containerSize }
            return containerSize
        }

        if let size = sizes[id] { return size }
        if containerSize.isUsableLayoutSize { sizes[id] = containerSize }
        return containerSize
    }

    mutating func prune(keeping ids: Set<Workspace.ID>) {
        sizes = sizes.filter { ids.contains($0.key) }
    }

    func cachedSize(for id: Workspace.ID) -> CGSize? {
        sizes[id]
    }
}

nonisolated extension CGSize {
    fileprivate var isUsableLayoutSize: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

/// A ZStack-like deck that measures only its active tab and parks every hidden
/// tab at its own stable size.
nonisolated struct PersistentTabDeckLayout: Layout {
    typealias Cache = PersistentTabDeckSizingState

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.prune(keeping: Set(subviews.compactMap { $0[PersistentTabDeckIDKey.self] }))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Cache
    ) -> CGSize {
        guard let active = subviews.first(where: { $0[PersistentTabDeckActiveKey.self] }) else {
            return proposal.replacingUnspecifiedDimensions()
        }

        let fitted = active.sizeThatFits(proposal)
        return CGSize(
            width: proposal.width ?? fitted.width,
            height: proposal.height ?? fitted.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        for subview in subviews {
            guard let id = subview[PersistentTabDeckIDKey.self] else { continue }
            let size = cache.size(
                for: id,
                isActive: subview[PersistentTabDeckActiveKey.self],
                containerSize: bounds.size
            )
            subview.place(
                at: bounds.origin,
                anchor: .topLeading,
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
        }
    }
}

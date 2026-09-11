import SwiftUI

/// The identity a Workspace contributes to `PersistentWorkspaceDeckLayout`.
private nonisolated struct PersistentWorkspaceDeckIDKey: LayoutValueKey {
    static let defaultValue: Workspace.ID? = nil
}

/// Whether a Workspace is the one the deck currently presents.
private nonisolated struct PersistentWorkspaceDeckActiveKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    func persistentWorkspaceDeckValue(id: Workspace.ID, isActive: Bool) -> some View {
        layoutValue(key: PersistentWorkspaceDeckIDKey.self, value: id)
            .layoutValue(key: PersistentWorkspaceDeckActiveKey.self, value: isActive)
    }
}

/// Per-Workspace proposals for a deck whose children must remain mounted.
///
/// The visible Workspace tracks the deck bounds. Hidden Workspaces keep their last visible
/// size so a sidebar animation cannot recursively lay out every parked split
/// tree and native terminal surface. A Workspace that has never been visible captures
/// the first usable deck size as its parking size.
nonisolated struct PersistentWorkspaceDeckSizingState {
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

/// A ZStack-like deck that measures only its active Workspace and parks every hidden
/// Workspace at its own stable size.
nonisolated struct PersistentWorkspaceDeckLayout: Layout {
    typealias Cache = PersistentWorkspaceDeckSizingState

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.prune(keeping: Set(subviews.compactMap { $0[PersistentWorkspaceDeckIDKey.self] }))
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout Cache
    ) -> CGSize {
        guard let active = subviews.first(where: { $0[PersistentWorkspaceDeckActiveKey.self] }) else {
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
            guard let id = subview[PersistentWorkspaceDeckIDKey.self] else { continue }
            let size = cache.size(
                for: id,
                isActive: subview[PersistentWorkspaceDeckActiveKey.self],
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

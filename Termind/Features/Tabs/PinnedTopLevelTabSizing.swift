import CoreGraphics

/// Pure sizing rules for the Vault and Assistant tabs pinned above the sidebar.
nonisolated enum PinnedTopLevelTabSizing {
    private static let tabCount: CGFloat = 2

    /// Divides the measured sidebar equally between the two pinned tabs.
    static func tabWidth(sidebarWidth: CGFloat) -> CGFloat {
        sidebarWidth / tabCount
    }

    /// Ignores transient invalid measurements produced while a sidebar leaves
    /// the split-view layout, preserving the last width for the pinned tabs.
    static func resolvedSidebarWidth(current: CGFloat, measured: CGFloat) -> CGFloat {
        guard measured.isFinite, measured > 0 else { return current }
        return measured
    }
}

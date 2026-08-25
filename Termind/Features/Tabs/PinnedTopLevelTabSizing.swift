import CoreGraphics

/// Pure sizing rules for the Vault and Assistant tabs pinned above the sidebar.
nonisolated enum PinnedTopLevelTabSizing {
    private static let tabCount: CGFloat = 2

    /// Divides the strip ending at the sidebar's trailing edge equally between
    /// the two pinned tabs.
    static func tabWidth(stripWidth: CGFloat) -> CGFloat {
        stripWidth / tabCount
    }

    /// Ignores invalid or collapsed detail-column edges produced while a
    /// sidebar leaves the split-view layout, preserving the last strip width.
    /// AppKit may leave the hidden edge at a hairline rather than exactly zero,
    /// so validity is based on the split view's existing minimum sidebar width.
    static func resolvedStripWidth(
        current: CGFloat,
        measuredDetailLeadingEdge: CGFloat,
        isSidebarVisible: Bool,
        minimumSidebarWidth: CGFloat
    ) -> CGFloat {
        guard
            isSidebarVisible,
            measuredDetailLeadingEdge.isFinite,
            measuredDetailLeadingEdge >= minimumSidebarWidth
        else {
            return current
        }
        return measuredDetailLeadingEdge
    }
}

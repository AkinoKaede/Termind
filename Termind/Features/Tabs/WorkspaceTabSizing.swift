import CoreGraphics

/// Pure width allocation for the scrolling Workspace portion of the tab bar.
///
/// Tabs shrink together until a title would become too narrow. After that the
/// selected Workspace keeps one titled slot while its neighbours continue down
/// to the icon-only compact width. Once every width reaches its floor, returning
/// more content than the viewport is intentional: `ScrollView` becomes the
/// overflow mechanism.
nonisolated enum WorkspaceTabSizing {
    static func widths(
        availableWidth: CGFloat,
        tabCount: Int,
        selectedIndex: Int?
    ) -> [CGFloat] {
        guard tabCount > 0 else { return [] }

        let availableWidth = availableWidth.isFinite ? max(availableWidth, 0) : 0
        let equalWidth = min(
            Metrics.TabBar.maxTabWidth,
            max(Metrics.TabBar.compactTabWidth, availableWidth / CGFloat(tabCount))
        )
        guard let selectedIndex, (0..<tabCount).contains(selectedIndex) else {
            return Array(repeating: equalWidth, count: tabCount)
        }

        if tabCount == 1 {
            return [
                min(
                    Metrics.TabBar.maxTabWidth,
                    max(Metrics.TabBar.titledTabMinWidth, availableWidth)
                )
            ]
        }
        guard equalWidth < Metrics.TabBar.titledTabMinWidth else {
            return Array(repeating: equalWidth, count: tabCount)
        }

        let remainingWidth = availableWidth - Metrics.TabBar.titledTabMinWidth
        let neighbourWidth = min(
            Metrics.TabBar.maxTabWidth,
            max(
                Metrics.TabBar.compactTabWidth,
                remainingWidth / CGFloat(tabCount - 1)
            )
        )
        var widths = Array(repeating: neighbourWidth, count: tabCount)
        widths[selectedIndex] = Metrics.TabBar.titledTabMinWidth
        return widths
    }
}

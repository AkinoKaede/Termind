import CoreGraphics
import Testing

@testable import Termind

@Suite
struct PinnedTopLevelTabSizingTests {
    @Test(arguments: [
        (Metrics.Sidebar.min, Metrics.Sidebar.min / 2),
        (Metrics.Sidebar.ideal, Metrics.Sidebar.ideal / 2),
        (Metrics.Sidebar.max, Metrics.Sidebar.max / 2),
    ])
    func twoPinnedTabsSplitAtTheSidebarTrailingEdgeEqually(
        stripWidth: CGFloat,
        expectedTabWidth: CGFloat
    ) {
        let tabWidth = PinnedTopLevelTabSizing.tabWidth(stripWidth: stripWidth)

        #expect(tabWidth == expectedTabWidth)
        #expect(tabWidth * 2 == stripWidth)
    }

    @Test(arguments: [CGFloat.zero, 1, Metrics.Sidebar.min - 1, -.infinity, .infinity, .nan])
    func invalidOrCollapsedDetailLeadingEdgesPreserveTheLastStripWidth(
        measuredDetailLeadingEdge: CGFloat
    ) {
        let currentWidth = Metrics.Sidebar.ideal

        #expect(
            PinnedTopLevelTabSizing.resolvedStripWidth(
                current: currentWidth,
                measuredDetailLeadingEdge: measuredDetailLeadingEdge,
                isSidebarVisible: true,
                minimumSidebarWidth: Metrics.Sidebar.min
            ) == currentWidth
        )
    }

    @Test
    func positiveDetailLeadingEdgeReplacesThePreviousStripWidth() {
        #expect(
            PinnedTopLevelTabSizing.resolvedStripWidth(
                current: Metrics.Sidebar.ideal,
                measuredDetailLeadingEdge: 270.5,
                isSidebarVisible: true,
                minimumSidebarWidth: Metrics.Sidebar.min
            ) == 270.5
        )
    }

    @Test
    func visibleAnimationMeasurementsDoNotReplaceTheLastStripWidthAfterHiding() {
        #expect(
            PinnedTopLevelTabSizing.resolvedStripWidth(
                current: 400.5,
                measuredDetailLeadingEdge: 272,
                isSidebarVisible: false,
                minimumSidebarWidth: Metrics.Sidebar.min
            ) == 400.5
        )
    }
}

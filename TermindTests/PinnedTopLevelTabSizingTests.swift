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
    func twoPinnedTabsSplitTheSidebarWidthEqually(
        sidebarWidth: CGFloat,
        expectedTabWidth: CGFloat
    ) {
        let tabWidth = PinnedTopLevelTabSizing.tabWidth(sidebarWidth: sidebarWidth)

        #expect(tabWidth == expectedTabWidth)
        #expect(tabWidth * 2 == sidebarWidth)
    }

    @Test(arguments: [CGFloat.zero, -.infinity, .infinity, .nan])
    func invalidMeasurementsPreserveTheLastSidebarWidth(measuredWidth: CGFloat) {
        let currentWidth = Metrics.Sidebar.ideal

        #expect(
            PinnedTopLevelTabSizing.resolvedSidebarWidth(
                current: currentWidth,
                measured: measuredWidth
            ) == currentWidth
        )
    }

    @Test
    func positiveMeasurementReplacesThePreviousSidebarWidth() {
        #expect(
            PinnedTopLevelTabSizing.resolvedSidebarWidth(
                current: Metrics.Sidebar.ideal,
                measured: Metrics.Sidebar.max
            ) == Metrics.Sidebar.max
        )
    }
}

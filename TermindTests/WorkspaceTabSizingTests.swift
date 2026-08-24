import Testing

@testable import Termind

@Suite
struct WorkspaceTabSizingTests {
    @Test
    func noTabsProducesNoWidths() {
        #expect(
            WorkspaceTabSizing.widths(
                availableWidth: 600,
                tabCount: 0,
                selectedIndex: nil
            ).isEmpty
        )
    }

    @Test
    func abundantSpaceCapsEveryTabAtMaximumWidth() {
        let widths = WorkspaceTabSizing.widths(
            availableWidth: 900,
            tabCount: 3,
            selectedIndex: 1
        )

        #expect(widths == [240, 240, 240])
    }

    @Test
    func tabsShrinkEquallyWhileEveryTitleStillFits() {
        let widths = WorkspaceTabSizing.widths(
            availableWidth: 540,
            tabCount: 3,
            selectedIndex: 1
        )

        #expect(widths == [180, 180, 180])
        #expect(widths.reduce(0, +) == 540)
    }

    @Test
    func selectedTabKeepsTitledWidthWhileNeighboursContinueShrinking() {
        let widths = WorkspaceTabSizing.widths(
            availableWidth: 300,
            tabCount: 3,
            selectedIndex: 1
        )

        #expect(widths == [90, 120, 90])
        #expect(widths.reduce(0, +) == 300)
    }

    @Test
    func selectedTabAndCompactNeighboursOverflowAtTheirFloors() {
        let widths = WorkspaceTabSizing.widths(
            availableWidth: 200,
            tabCount: 3,
            selectedIndex: 1
        )

        #expect(widths == [48, 120, 48])
        #expect(widths.reduce(0, +) == 216)
    }

    @Test
    func tabsWithoutSelectedWorkspaceShareWidthDownToCompactFloor() {
        let shrinking = WorkspaceTabSizing.widths(
            availableWidth: 300,
            tabCount: 3,
            selectedIndex: nil
        )
        let overflowing = WorkspaceTabSizing.widths(
            availableWidth: 100,
            tabCount: 3,
            selectedIndex: nil
        )

        #expect(shrinking == [100, 100, 100])
        #expect(overflowing == [48, 48, 48])
    }

    @Test
    func loneSelectedTabKeepsItsTitleFloor() {
        let constrained = WorkspaceTabSizing.widths(
            availableWidth: 60,
            tabCount: 1,
            selectedIndex: 0
        )
        let abundant = WorkspaceTabSizing.widths(
            availableWidth: 1_000,
            tabCount: 1,
            selectedIndex: 0
        )

        #expect(constrained == [120])
        #expect(abundant == [240])
    }
}

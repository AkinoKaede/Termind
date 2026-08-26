import CoreGraphics
import Testing

@testable import Termind

@Suite
struct TranscriptScrollCoordinationTests {
    @Test
    func streamingGrowthFollowsWhenReaderIsAtLiveEdge() {
        #expect(adjustment(from: metrics(content: 800, viewport: 400, offset: 400),
                           to: metrics(content: 840, viewport: 400, offset: 400))
            == .followBottomAfterLayout)
    }

    @Test
    func disclosureGrowthPreservesTheCurrentViewport() {
        #expect(adjustment(from: metrics(content: 800, viewport: 400, offset: 400),
                           to: metrics(content: 1_200, viewport: 400, offset: 400),
                           suppressingExpansion: true) == .none)
    }

    @Test
    func contentContractionImmediatelyRepairsAFollowingViewport() {
        #expect(adjustment(from: metrics(content: 1_200, viewport: 400, offset: 800),
                           to: metrics(content: 700, viewport: 400, offset: 800))
            == .repairBottomImmediately)
    }

    @Test
    func historyReaderKeepsAValidPositionWhenContentContracts() {
        #expect(adjustment(from: metrics(content: 1_200, viewport: 400, offset: 300),
                           to: metrics(content: 900, viewport: 400, offset: 300),
                           following: false) == .none)
    }

    @Test
    func historyReaderGetsOnlyTheRequiredRepairWhenOldOffsetIsInvalid() {
        #expect(adjustment(from: metrics(content: 1_200, viewport: 400, offset: 700),
                           to: metrics(content: 900, viewport: 400, offset: 700),
                           following: false) == .repairBottomImmediately)
    }

    @Test
    func blockingSurfaceResizeKeepsAFollowingViewportAtTheBottom() {
        #expect(adjustment(from: metrics(content: 800, viewport: 500, offset: 300),
                           to: metrics(content: 800, viewport: 280, offset: 300))
            == .repairBottomImmediately)
    }

    @Test
    func viewportGrowthRepairsAnInvalidHistoryOffset() {
        #expect(adjustment(from: metrics(content: 800, viewport: 280, offset: 520),
                           to: metrics(content: 800, viewport: 500, offset: 520),
                           following: false) == .repairBottomImmediately)
    }

    @Test
    func directScrollingNeverTriggersProgrammaticAdjustment() {
        #expect(adjustment(from: metrics(content: 1_200, viewport: 400, offset: 800),
                           to: metrics(content: 700, viewport: 400, offset: 800),
                           userScrolling: true) == .none)
    }

    @Test
    func subpixelLayoutNoiseDoesNotTriggerARepairOrFollowRequest() {
        #expect(adjustment(from: metrics(content: 800, viewport: 400, offset: 400),
                           to: metrics(content: 800.25, viewport: 400.25, offset: 400))
            == .none)
    }

    private func adjustment(
        from old: TranscriptScrollMetrics,
        to new: TranscriptScrollMetrics,
        following: Bool = true,
        userScrolling: Bool = false,
        suppressingExpansion: Bool = false
    ) -> TranscriptScrollAdjustment {
        TranscriptScrollCoordination.adjustment(
            from: old, to: new, isFollowingBottom: following,
            isUserScrolling: userScrolling,
            isSuppressingDisclosureExpansion: suppressingExpansion
        )
    }

    private func metrics(
        content: CGFloat, viewport: CGFloat, offset: CGFloat
    ) -> TranscriptScrollMetrics {
        TranscriptScrollMetrics(
            isAtBottom: offset + viewport >= content - Metrics.Space.l,
            contentHeight: content, viewportHeight: viewport,
            visibleMinY: offset
        )
    }
}

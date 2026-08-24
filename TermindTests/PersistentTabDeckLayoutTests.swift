import Foundation
import Testing

@testable import Termind

@Suite
@MainActor
struct PersistentTabDeckLayoutTests {
    @Test
    func activeTabTracksContainerWhileHiddenTabKeepsItsLastSize() {
        var state = PersistentTabDeckSizingState()
        let tab = UUID()
        let initial = CGSize(width: 900, height: 600)
        let narrower = CGSize(width: 620, height: 600)

        #expect(state.size(for: tab, isActive: true, containerSize: initial) == initial)
        #expect(state.size(for: tab, isActive: false, containerSize: narrower) == initial)
        #expect(state.cachedSize(for: tab) == initial)
    }

    @Test
    func neverVisibleTabCapturesItsFirstUsableParkingSize() {
        var state = PersistentTabDeckSizingState()
        let tab = UUID()
        let first = CGSize(width: 780, height: 520)
        let later = CGSize(width: 540, height: 520)

        #expect(state.size(for: tab, isActive: false, containerSize: .zero) == .zero)
        #expect(state.cachedSize(for: tab) == nil)
        #expect(state.size(for: tab, isActive: false, containerSize: first) == first)
        #expect(state.size(for: tab, isActive: false, containerSize: later) == first)
    }

    @Test
    func switchingTabsParksTheOldTabAtItsFinalActiveSize() {
        var state = PersistentTabDeckSizingState()
        let first = UUID()
        let second = UUID()
        let original = CGSize(width: 800, height: 500)
        let final = CGSize(width: 960, height: 500)

        _ = state.size(for: first, isActive: true, containerSize: original)
        _ = state.size(for: second, isActive: false, containerSize: original)
        _ = state.size(for: first, isActive: true, containerSize: final)

        #expect(state.size(for: first, isActive: false, containerSize: final) == final)
        #expect(state.size(for: second, isActive: true, containerSize: final) == final)
    }

    @Test
    func cacheUsesIdentityAcrossReorderingAndPrunesClosedTabs() {
        var state = PersistentTabDeckSizingState()
        let first = UUID()
        let second = UUID()
        let firstSize = CGSize(width: 700, height: 480)
        let secondSize = CGSize(width: 920, height: 640)

        _ = state.size(for: first, isActive: true, containerSize: firstSize)
        _ = state.size(for: second, isActive: true, containerSize: secondSize)

        // Reading in reverse order does not exchange the cached proposals.
        #expect(state.size(for: second, isActive: false, containerSize: firstSize) == secondSize)
        #expect(state.size(for: first, isActive: false, containerSize: secondSize) == firstSize)

        state.prune(keeping: [second])
        #expect(state.cachedSize(for: first) == nil)
        #expect(state.cachedSize(for: second) == secondSize)
    }
}

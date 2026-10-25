// SPDX-FileCopyrightText: 2026 Kaede Akino
// SPDX-License-Identifier: GPL-3.0-only

import Observation
import SwiftUI
import Testing
import UIKit

@testable import TermindIOS

@Suite @MainActor
struct MobileCardReorderSessionTests {
    @Test func registeringAndRemovingIdleDragRegionsDoesNotInvalidateCardLayout() {
        let state = MobileCardReorderSession()
        let scrollView = UIScrollView()
        let region = MobileCardDragRegion.RegionView()
        scrollView.addSubview(region)
        withObservationTracking {
            _ = state.payload
            _ = state.placement
            _ = state.size
        } onChange: {
            Issue.record("Registering idle drag interactions must not invalidate the observed card layout")
        }
        state.interaction.register(region)
        state.interaction.register(region)
        #expect(scrollView.interactions.contains { $0 is UIDragInteraction })
        state.interaction.unregister(region)
        state.interaction.uninstall()
        state.cancel()
        #expect(!scrollView.interactions.contains { $0 is UIDragInteraction })
    }

    @Test func hoveringStagesNeighborMovementAndCommitsOnlyOnce() throws {
        let state = MobileCardReorderSession()
        let section = MobileCardSectionID(collection: .hosts)
        let ids = (0..<5).map { _ in UUID() }
        var writes: [MobileCardMove] = []
        state.begin(id: ids[0], section: section, orderedIDs: ids, size: CGSize(width: 90, height: 106))
        #expect(state.projectedIDs(ids, in: section) == ids)
        #expect(
            state.stage(MobileCardMove(id: ids[0], before: ids[4]), in: section) {
                writes.append(MobileCardMove(id: $0, before: $1))
            })
        #expect(state.projectedIDs(ids, in: section) == [ids[1], ids[2], ids[3], ids[0], ids[4]])
        #expect(writes.isEmpty)
        #expect(!state.stage(MobileCardMove(id: ids[0], before: ids[4]), in: section) { _, _ in })
        state.commit()
        state.commit()
        #expect(writes == [MobileCardMove(id: ids[0], before: ids[4])])
        #expect(state.payload == nil)
    }

    @Test func crossGroupDraftReservesOneSlotAndCancellationRestoresBothGroups() {
        let state = MobileCardReorderSession()
        let source = MobileCardSectionID(collection: .snippets, group: UUID())
        let destination = MobileCardSectionID(collection: .snippets, group: UUID())
        let ids = (0..<4).map { _ in UUID() }
        var writes = 0
        state.begin(id: ids[0], section: source, orderedIDs: [ids[0], ids[1]], size: CGSize(width: 90, height: 106))
        state.stage(MobileCardMove(id: ids[0], before: ids[3]), in: destination) { _, _ in writes += 1 }
        #expect(state.projectedIDs([ids[0], ids[1]], in: source) == [ids[1]])
        #expect(state.projectedIDs([ids[2], ids[3]], in: destination) == [ids[2], ids[0], ids[3]])
        state.cancel()
        #expect(state.projectedIDs([ids[0], ids[1]], in: source) == [ids[0], ids[1]])
        #expect(state.projectedIDs([ids[2], ids[3]], in: destination) == [ids[2], ids[3]])
        state.commit()
        #expect(writes == 0)
    }

    @Test func returningToOriginalSlotDoesNotWriteAndOtherCollectionsStayUnchanged() {
        let state = MobileCardReorderSession()
        let section = MobileCardSectionID(collection: .metrics)
        let ids = (0..<3).map { _ in UUID() }
        var writes = 0
        state.begin(id: ids[0], section: section, orderedIDs: ids, size: .zero)
        state.stage(MobileCardMove(id: ids[0], before: nil), in: section) { _, _ in writes += 1 }
        #expect(state.projectedIDs(ids, in: MobileCardSectionID(collection: .keys)) == ids)
        #expect(
            !state.stage(MobileCardMove(id: ids[0], before: nil), in: MobileCardSectionID(collection: .keys)) { _, _ in
                writes += 1
            })
        state.stage(MobileCardMove(id: ids[0], before: ids[1]), in: section) { _, _ in writes += 1 }
        state.commit()
        #expect(writes == 0)
    }

    @Test func invalidAndSecondSourcesCannotReplaceAnActiveDrag() {
        let state = MobileCardReorderSession()
        let section = MobileCardSectionID(collection: .hosts)
        let ids = (0..<2).map { _ in UUID() }
        state.begin(id: UUID(), section: section, orderedIDs: ids, size: .zero)
        #expect(state.payload == nil)
        state.begin(id: ids[0], section: section, orderedIDs: ids, size: .zero)
        state.begin(id: ids[1], section: section, orderedIDs: ids, size: .zero)
        #expect(state.payload?.id == ids[0])
    }
}

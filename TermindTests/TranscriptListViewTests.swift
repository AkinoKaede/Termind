import Foundation
import SwiftUI
import Testing

@testable import Termind

@Suite
struct TranscriptListUpdatePlanTests {
    @Test
    func firstSnapshotUsesApply() {
        let plan = TranscriptListUpdatePlan.make(old: [], new: [item(1)])

        #expect(plan.replacesAll)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends.isEmpty)
    }

    @Test
    func pureTailGrowthUsesAppendWithoutRevisitingExistingRows() {
        let first = item(1)
        let second = item(2)
        let plan = TranscriptListUpdatePlan.make(old: [first], new: [first, second])

        #expect(!plan.replacesAll)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends == [second])
    }

    @Test
    func aStreamingRevisionUpdatesOnlyItsStableRow() {
        let id = uuid(1)
        let old = TranscriptRenderItem(id: id, content: .empty)
        let new = TranscriptRenderItem(id: id, content: .interrupted)
        let untouched = item(2)
        let plan = TranscriptListUpdatePlan.make(
            old: [old, untouched], new: [new, untouched]
        )

        #expect(!plan.replacesAll)
        #expect(plan.updates == [new])
        #expect(plan.appends.isEmpty)
    }

    @Test
    func removalOrReorderingFallsBackToDiffedApply() {
        let first = item(1)
        let second = item(2)

        #expect(TranscriptListUpdatePlan.make(
            old: [first, second], new: [second, first]
        ).replacesAll)
        #expect(TranscriptListUpdatePlan.make(
            old: [first, second], new: [first]
        ).replacesAll)
    }

    @Test
    func appendingMarksOnlyTheNewRowForLeadingSpacing() {
        let firstTimeline = TimelineItem.message(ChatMessage(
            id: uuid(1), role: .assistant, text: "first"
        ))
        let secondTimeline = TimelineItem.message(ChatMessage(
            id: uuid(2), role: .assistant, text: "second"
        ))

        let old = TranscriptRenderItem.items(
            timeline: [firstTimeline], isInterrupted: false
        )
        let new = TranscriptRenderItem.items(
            timeline: [firstTimeline, secondTimeline], isInterrupted: false
        )
        let plan = TranscriptListUpdatePlan.make(old: old, new: new)

        #expect(!old[0].hasLeadingSpacing)
        #expect(!new[0].hasLeadingSpacing)
        #expect(new[1].hasLeadingSpacing)
        #expect(plan.updates.isEmpty)
        #expect(plan.appends == [new[1]])
    }

    private func item(_ value: UInt8) -> TranscriptRenderItem {
        TranscriptRenderItem(id: uuid(value), content: .empty)
    }

    private func uuid(_ value: UInt8) -> UUID {
        let bytes = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value)
        return UUID(uuid: bytes)
    }
}

@MainActor
@Suite
struct TranscriptPresentationStateTests {
    @Test
    func aReaderToggleSurvivesDefaultStateTransitions() {
        let id = UUID()
        let state = TranscriptPresentationState()

        #expect(state.isExpanded(id, default: true))
        state.toggleDisclosure(id, default: true)
        #expect(!state.isExpanded(id, default: true))
        #expect(state.readerDidToggle(id))

        state.followDefault(true, for: id)
        #expect(!state.isExpanded(id, default: true))
    }

    @Test
    func untouchedDisclosureFollowsItsRuntimeDefault() {
        let id = UUID()
        let state = TranscriptPresentationState()

        state.followDefault(true, for: id)
        #expect(state.isExpanded(id))
        #expect(!state.readerDidToggle(id))
    }

    @Test
    func messageDraftSurvivesRowRecyclingAndCanBePruned() {
        let id = UUID()
        let state = TranscriptPresentationState()

        state.beginEditingMessage(id, text: "draft")
        state.setMessageEditText("updated", for: id)
        state.setMessageBubbleWidth(240, for: id)

        #expect(state.isEditingMessage(id))
        #expect(state.messageEditText(id) == "updated")
        #expect(state.messageBubbleWidth(id) == 240)

        state.prune(validTimelineIDs: [])
        #expect(!state.isEditingMessage(id))
        #expect(state.messageEditText(id).isEmpty)
    }
}

@MainActor
@Suite
struct TranscriptListViewBridgeTests {
    @Test
    func installsTheSubtleBouncyAnimator() throws {
        let listView = TranscriptListView.Coordinator().makeListView()
        let animator = try #require(listView.rowAnimator)
        let values = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: animator).children.compactMap { child in
                child.label.map { ($0, child.value) }
            }
        )

        #expect(String(describing: type(of: animator)) == "ListBouncyAnimator")
        #expect(values["damping"] as? CGFloat == 0.8)
        #expect(values["frequency"] as? CGFloat == 2)
    }

    @Test
    func hostedRowsUseTheirMeasuredIntrinsicHeights() {
        let coordinator = TranscriptListView.Coordinator()
        let listView = coordinator.makeListView()
        let short = TranscriptRenderItem(id: UUID(), content: .empty)
        let tall = TranscriptRenderItem(
            id: UUID(), content: .interrupted, hasLeadingSpacing: true
        )
        listView.frame = CGRect(x: 0, y: 0, width: 320, height: 400)

        coordinator.update(
            listView: listView,
            items: [short, tall],
            latestUserMessageID: nil,
            renderer: { item, _ in
                AnyView(
                    Text(item.id == short.id
                        ? "Short"
                        : String(repeating: "A wrapping transcript line. ", count: 80))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                )
            },
            environment: .init(locale: Locale(identifier: "en"), colorScheme: .light)
        )
        listView.layoutSubtreeIfNeeded()

        let shortHeight = listView.rectForRow(with: short.id).height
        let tallHeight = listView.rectForRow(with: tall.id).height
        #expect(shortHeight > 0)
        #expect(tallHeight > 96)
        #expect(tallHeight > shortHeight)
    }
}
